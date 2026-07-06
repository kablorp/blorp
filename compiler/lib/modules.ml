(** Module System for blorp

    Handles module loading, path resolution, and caching.
*)

open Ast

(** Substring search: check if [s] contains [sub] *)
let contains s sub =
  let slen = String.length s and sublen = String.length sub in
  if sublen > slen then false
  else
    let rec check i =
      if i > slen - sublen then false
      else if String.sub s i sublen = sub then true
      else check (i + 1)
    in
    check 0

type loaded_module = Session.loaded_module = {
  name : string;
  path : string;
  origin : Session.module_origin;
  decls : program;
  exports : (string * decl) list;
  surface : Module_surface.t option;
  mutable typed_decls : Typed_ast.program option;
  mutable typed_import_bindings : Session.import_binding list option;
}
(** Module representation — imported from [Session] where it lives
    alongside the per-session module cache. Re-exported here so existing
    callers keep seeing [Modules.loaded_module]. *)

type preloaded_parsed_source = {
  preload_module_name : string;
  preload_path : string;
  preload_origin : Session.module_origin;
  preload_source : string;
  preload_decls : Ast.program;
  preload_surface : Module_surface.t option;
}

type preloaded_import_edge = {
  preload_import_from_path : string;
  preload_import_from_module : string;
  preload_import_path : string;
  preload_import_resolved_path : string option;
  preload_import_resolved_module : string option;
  preload_import_resolved_origin : Session.module_origin option;
}

(** Resolve the session to operate on: explicit if passed, else the
    ambient current session. Every stateful function in this module
    uses this pattern so callers that don't carry a session in scope
    (the formatter, the LSP's request handlers, test helpers) rely on
    the ambient session set by frontend entry points. *)
let sess_of ?sess () =
  match sess with Some s -> s | None -> Session.current ()

let has_prefix prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let strip_prefix prefix s =
  String.sub s (String.length prefix) (String.length s - String.length prefix)

let canonical_dir dir = try Unix.realpath dir with _ -> dir

let canonical_file path =
  let path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
    else path
  in
  try Unix.realpath path with _ -> path

let is_path_under_dir ~dir path =
  let dir = canonical_dir dir in
  let path = canonical_file path in
  path = dir
  ||
  let prefix = dir ^ Filename.dir_sep in
  String.length path > String.length prefix
  && String.sub path 0 (String.length prefix) = prefix

let relative_path_under_dir ~dir path =
  let dir = canonical_dir dir in
  let path = canonical_file path in
  let prefix = dir ^ Filename.dir_sep in
  if
    String.length path > String.length prefix
    && String.sub path 0 (String.length prefix) = prefix
  then
    Some
      (String.sub path (String.length prefix)
         (String.length path - String.length prefix))
  else None

let source_package_for_path (s : Session.t) path =
  List.find_opt
    (fun (pkg : Session.source_package) ->
      is_path_under_dir ~dir:pkg.source_package_source_dir path)
    s.source_packages

let is_package_loaded_module (m : loaded_module) =
  Session.module_origin_is_package m.origin

let is_std_source_file ?sess path =
  let s = sess_of ?sess () in
  if has_prefix "<embedded:std/" path then true
  else
    match s.std_source_dir with
    | Some dir -> is_path_under_dir ~dir path
    | None -> false

let normalize_module_path path =
  String.map (function '\\' -> '/' | c -> c) path

let std_module_name_for_source_file ?sess path =
  let s = sess_of ?sess () in
  if has_prefix "<embedded:std/" path then
    let prefix = "<embedded:" in
    let plen = String.length prefix in
    let len = String.length path in
    if len > plen && path.[len - 1] = '>' then
      Some (String.sub path plen (len - plen - 1))
    else None
  else
    match s.std_source_dir with
    | None -> None
    | Some std_dir ->
        let std_dir = canonical_dir std_dir in
        let path = canonical_file path in
        if not (is_path_under_dir ~dir:std_dir path) then None
        else
          let prefix = std_dir ^ Filename.dir_sep in
          if String.length path <= String.length prefix then None
          else
            let rel =
              String.sub path (String.length prefix)
                (String.length path - String.length prefix)
            in
            if not (Filename.check_suffix rel ".brp") then None
            else
              let without_ext = String.sub rel 0 (String.length rel - 4) in
              Some ("std/" ^ normalize_module_path without_ext)

let source_package_module_name_for_source_file (s : Session.t) path =
  match source_package_for_path s path with
  | None -> None
  | Some pkg -> (
      match relative_path_under_dir ~dir:pkg.source_package_source_dir path with
      | None -> None
      | Some rel ->
          if not (Filename.check_suffix rel ".brp") then None
          else
            let without_ext = String.sub rel 0 (String.length rel - 4) in
            Some (normalize_module_path without_ext))

let module_name_for_source_file ?sess path =
  match std_module_name_for_source_file ?sess path with
  | Some _ as name -> name
  | None -> source_package_module_name_for_source_file (sess_of ?sess ()) path

let module_origin_for_source_file ?sess path =
  if is_std_source_file ?sess path then Session.Stdlib_module
  else
    match source_package_for_path (sess_of ?sess ()) path with
    | Some pkg -> Session.package_origin pkg.source_package_alias
    | None -> Session.User_module

let is_directory path =
  try Sys.file_exists path && Sys.is_directory path with _ -> false

let bridge_module_name_for_path ?sess path =
  match module_name_for_source_file ?sess path with
  | Some name -> name
  | None ->
      let base = Filename.basename path in
      if Filename.check_suffix base ".brp" then
        String.sub base 0 (String.length base - 4)
      else base

let parse_error_for_message ?filename message =
  let loc =
    match filename with
    | Some file -> Ast.point_loc_in ~file ~line:1 ~column:1
    | None -> Ast.point_loc ~line:1 ~column:1
  in
  {
    Ast.message = message;
    loc;
    phase = Ast.Parse;
    kind = Ast.OtherError;
    notes = [];
    help = None;
  }

type bridge_parse_error =
  | BridgeParseMessage of string
  | BridgeParseCompilerErrors of Ast.compiler_error list

let parse_source_artifact_with_blorp_bridge
    ?(phase = Compiler_blorp_bridge.RawParsedProgram) ~path ~module_name
    ~bridge_read_file source =
  let parse_result =
    if bridge_read_file then
      Compiler_blorp_bridge.parse_source_file_via_command_at_phase ~phase ~path
        ~module_name
    else
      Compiler_blorp_bridge.parse_source_via_command_at_phase ~phase ~path
        ~module_name ~text:source
  in
  match
    parse_result
  with
  | Error (_, message) -> Error (BridgeParseMessage message)
  | Ok (Compiler_blorp_bridge.ParseSourceDiagnostics diagnostics) ->
      Error (BridgeParseCompilerErrors diagnostics)
  | Ok (Compiler_blorp_bridge.ParsedSource parsed_source) ->
      Ok parsed_source

let parse_source_with_blorp_bridge ?phase ~path ~module_name ~bridge_read_file
    source =
  match
    parse_source_artifact_with_blorp_bridge ?phase ~path ~module_name
      ~bridge_read_file source
  with
  | Ok parsed_source -> Ok parsed_source.parsed_program
  | Error _ as error -> error

(** Record the explicit filesystem std directory for this session. *)
let record_std_source_dir (s : Session.t) dir =
  let dir = canonical_dir dir in
  s.std_source_dir <- Some dir;
  if not (List.mem dir s.search_paths) then
    s.search_paths <- dir :: s.search_paths

(** Record an explicit local package root. The root is the directory
    containing package directories/files, usually [<project>/pkg]. *)
let add_package_root ?sess dir =
  let s = sess_of ?sess () in
  let dir = canonical_dir dir in
  if not (List.mem dir s.package_roots) then
    s.package_roots <- dir :: s.package_roots

(** Package roots configured for this session, in lookup order. *)
let package_roots ?sess () = (sess_of ?sess ()).package_roots

type source_package = Session.source_package = {
  source_package_alias : string;
  source_package_name : string;
  source_package_root : string;
  source_package_source_dir : string;
  source_package_exports : string list;
}

type preloaded_module_graph_context = {
  preload_graph_std_dir : string option;
  preload_graph_source_packages : source_package list;
  preload_graph_package_roots : string list;
}

type preloaded_module_graph = {
  preload_graph_context : preloaded_module_graph_context;
  preload_graph_sources : preloaded_parsed_source list;
  preload_graph_imports : preloaded_import_edge list;
}

let add_source_package ?sess (pkg : source_package) =
  let s = sess_of ?sess () in
  s.source_packages <-
    pkg
    :: List.filter
         (fun existing ->
           existing.source_package_alias <> pkg.source_package_alias)
         s.source_packages

(** Look up typed AST for a module from the module cache. *)
let get_typed_decls ?sess name =
  let s = sess_of ?sess () in
  match Hashtbl.find_opt s.module_cache name with
  | Some m -> m.typed_decls
  | None -> None

(** Store typed AST for a module in the module cache. *)
let set_typed_decls ?sess name typed_decls =
  let s = sess_of ?sess () in
  match Hashtbl.find_opt s.module_cache name with
  | Some m -> m.typed_decls <- Some typed_decls
  | None -> ()

(** Look up resolved import bindings for a typed module from the module cache. *)
let get_typed_import_bindings ?sess name =
  let s = sess_of ?sess () in
  match Hashtbl.find_opt s.module_cache name with
  | Some m -> m.typed_import_bindings
  | None -> None

(** Store resolved import bindings for a typed module in the module cache. *)
let set_typed_import_bindings ?sess name bindings =
  let s = sess_of ?sess () in
  match Hashtbl.find_opt s.module_cache name with
  | Some m -> m.typed_import_bindings <- Some bindings
  | None -> ()

(** Get accumulated module loading errors. *)
let get_load_errors ?sess () = (sess_of ?sess ()).load_errors

(** Add a search path to the ambient (or given) session. *)
let add_search_path ?sess path =
  let s = sess_of ?sess () in
  if not (List.mem path s.search_paths) then
    s.search_paths <- path :: s.search_paths

(** Override the embedded std library with a filesystem directory.
    Higher priority than BLORP_STD env var and blorp.toml. *)
let set_std_override ?sess dir =
  let s = sess_of ?sess () in
  s.std_override_dir <- Some dir;
  s.std_override_active <- true;
  record_std_source_dir s dir

(** Filesystem std source directory established by [init_module_paths] or
    [set_std_override]. *)
let std_source_dir ?sess () = (sess_of ?sess ()).std_source_dir

(** Check if a file exists *)
let file_exists path =
  try
    let _ = Unix.stat path in
    true
  with Unix.Unix_error _ -> false

(** Extract directory from a path *)
let extract_directory path =
  let dir = Filename.dirname path in
  if dir = "" then "." else dir

(** Resolve module path to actual file path
    @param base_dir Directory of the importing file
    @param module_name Module name like "std/List", "./utils", "../lib/helper"
    @return Some(path) if found, None otherwise
*)

let eager_typecheck_support_modules =
  [
    "bool";
    "option";
    "result";
    "traits";
    "int";
    "float";
    "float32";
    "float16";
    "char";
    "bytes";
    "string";
    "list";
    "dict";
    "set";
    "tuple";
    "io";
    "system";
    "prelude";
    "parallel_list";
    "parallel_vector";
    "parallel_matrix";
  ]

let find_cached_by_path (sess : Session.t) (path : string) :
    loaded_module option =
  Hashtbl.fold
    (fun _ m acc ->
      match acc with
      | Some _ -> acc
      | None -> if m.path = path then Some m else None)
    sess.module_cache None

type resolved_module_file = {
  resolved_path : string;
  resolved_origin : Session.module_origin;
}

type package_ref = { package_id : string; package_path : string }

let package_ref_of_module_name module_name =
  if not (has_prefix "pkg/" module_name) then None
  else
    let rest = strip_prefix "pkg/" module_name in
    match String.split_on_char '/' rest with
    | package_id :: _ when package_id <> "" ->
        Some { package_id; package_path = rest }
    | _ -> None

let split_module_ref module_name =
  match String.split_on_char '/' module_name with
  | [] | [ "" ] -> None
  | head :: rest when head <> "" -> Some (head, String.concat "/" rest)
  | _ -> None

let source_package_for_base_dir (s : Session.t) base_dir =
  source_package_for_path s base_dir

let source_package_origin_for_relative_target (s : Session.t) base_dir candidate
    =
  match source_package_for_base_dir s base_dir with
  | None -> Some Session.User_module
  | Some pkg ->
      if is_path_under_dir ~dir:pkg.source_package_source_dir candidate then
        Some (Session.package_origin pkg.source_package_alias)
      else None

let source_package_module_file source_dir module_path =
  let with_ext name =
    if Filename.check_suffix name ".brp" then name else name ^ ".brp"
  in
  with_ext (Filename.concat source_dir (normalize_module_path module_path))

let resolve_source_package_internal_import (s : Session.t) base_dir module_name
    =
  match source_package_for_base_dir s base_dir with
  | None -> None
  | Some pkg ->
      if
        module_name = pkg.source_package_name
        || has_prefix (pkg.source_package_name ^ "/") module_name
      then
        let candidate =
          source_package_module_file pkg.source_package_source_dir module_name
        in
        if file_exists candidate then
          Some
            {
              resolved_path = candidate;
              resolved_origin = Session.package_origin pkg.source_package_alias;
            }
        else None
      else None

let source_package_export_for_alias pkg module_name =
  match split_module_ref module_name with
  | None -> None
  | Some (head, rest) when head = pkg.source_package_alias ->
      let package_module =
        if rest = "" then pkg.source_package_name
        else pkg.source_package_name ^ "/" ^ rest
      in
      if List.mem package_module pkg.source_package_exports then
        Some package_module
      else None
  | Some _ -> None

let resolve_source_package_alias (s : Session.t) module_name =
  List.find_map
    (fun pkg ->
      match source_package_export_for_alias pkg module_name with
      | None -> None
      | Some package_module ->
          let candidate =
            source_package_module_file pkg.source_package_source_dir
              package_module
          in
          if file_exists candidate then
            Some
              {
                resolved_path = candidate;
                resolved_origin =
                  Session.package_origin pkg.source_package_alias;
              }
          else None)
    s.source_packages

let source_package_alias_for_module (s : Session.t) module_name =
  match split_module_ref module_name with
  | None -> None
  | Some (head, _) ->
      List.find_opt
        (fun (pkg : Session.source_package) -> pkg.source_package_alias = head)
        s.source_packages

let source_package_alias_module_name pkg module_name =
  match split_module_ref module_name with
  | Some (head, rest) when head = pkg.source_package_alias ->
      if rest = "" then Some pkg.source_package_name
      else Some (pkg.source_package_name ^ "/" ^ rest)
  | _ -> None

let source_package_alias_load_error (s : Session.t) module_name =
  match source_package_alias_for_module s module_name with
  | None -> None
  | Some pkg -> (
      match source_package_alias_module_name pkg module_name with
      | None -> None
      | Some package_module ->
          if List.mem package_module pkg.source_package_exports then
            let path =
              source_package_module_file pkg.source_package_source_dir
                package_module
            in
            Some
              (Printf.sprintf
                 "package alias %S exports module %S as %S, but %s was not \
                  found"
                 pkg.source_package_alias module_name package_module path)
          else
            let exports = String.concat ", " pkg.source_package_exports in
            Some
              (Printf.sprintf
                 "package alias %S does not export module %S\n\
                 \  = help: Import one of the package's exported modules: %s"
                 pkg.source_package_alias module_name exports))

let rec resolve_module_file ?sess base_dir module_name =
  let s = sess_of ?sess () in
  let with_ext name =
    if Filename.check_suffix name ".brp" then name else name ^ ".brp"
  in

  if has_prefix "std/" module_name then
    let rest = strip_prefix "std/" module_name in
    match s.std_source_dir with
    | Some std_dir ->
        let candidate = with_ext (Filename.concat std_dir rest) in
        if file_exists candidate then
          Some
            {
              resolved_path = candidate;
              resolved_origin = Session.Stdlib_module;
            }
        else None
    | None -> None
  else
    match resolve_source_package_internal_import s base_dir module_name with
    | Some resolved -> Some resolved
    | None when Option.is_none (source_package_for_base_dir s base_dir) -> (
        match resolve_source_package_alias s module_name with
        | Some resolved -> Some resolved
        | None -> resolve_non_source_package_module ~sess:s base_dir module_name
        )
    | None -> resolve_non_source_package_module ~sess:s base_dir module_name

and resolve_non_source_package_module ~sess base_dir module_name =
  let s = sess in
  let with_ext name =
    if Filename.check_suffix name ".brp" then name else name ^ ".brp"
  in
  if has_prefix "pkg/" module_name then
    if
      (match s.std_source_dir with
        | Some std_dir -> is_path_under_dir ~dir:std_dir base_dir
        | None -> false)
      || Option.is_some (source_package_for_base_dir s base_dir)
    then None
    else
      match package_ref_of_module_name module_name with
      | None -> None
      | Some pkg ->
          List.find_map
            (fun root ->
              let candidate =
                with_ext (Filename.concat root pkg.package_path)
              in
              if file_exists candidate then
                Some
                  {
                    resolved_path = candidate;
                    resolved_origin =
                      Session.native_package_origin pkg.package_id;
                  }
              else None)
            s.package_roots
  else if has_prefix "./" module_name then
    let rest = strip_prefix "./" module_name in
    let candidate = with_ext (Filename.concat base_dir rest) in
    if file_exists candidate then
      Option.map
        (fun origin -> { resolved_path = candidate; resolved_origin = origin })
        (source_package_origin_for_relative_target s base_dir candidate)
    else None
  else if has_prefix "../" module_name then
    (* Walk up one directory per ../ prefix *)
    let rec resolve_dotdots dir name =
      if has_prefix "../" name then
        resolve_dotdots (Filename.dirname dir) (strip_prefix "../" name)
      else (dir, name)
    in
    let resolved_dir, rest = resolve_dotdots base_dir module_name in
    let candidate = with_ext (Filename.concat resolved_dir rest) in
    if file_exists candidate then
      Option.map
        (fun origin -> { resolved_path = candidate; resolved_origin = origin })
        (source_package_origin_for_relative_target s base_dir candidate)
    else None
  (* Default: try as-is relative to base_dir *)
    else
    let candidate = with_ext (Filename.concat base_dir module_name) in
    if
      file_exists candidate
      && Option.is_none (source_package_for_base_dir s base_dir)
    then
      Some { resolved_path = candidate; resolved_origin = Session.User_module }
    else None

let resolve_module_path ?sess base_dir module_name =
  resolve_module_file ?sess base_dir module_name
  |> Option.map (fun resolved -> resolved.resolved_path)

(** Read a file's contents (exception-safe) *)
let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let n = in_channel_length ic in
      really_input_string ic n)

let source_hash source = Digest.to_hex (Digest.string source)
let embedded_module_path path = has_prefix "<embedded:" path

type cached_module_source = {
  cached_path : string;
  cached_origin : Session.module_origin;
  cached_decls : program;
  cached_exports : (string * decl) list;
  cached_surface : Module_surface.t option;
}

let cached_module_source_of_entry
    (entry : Session.parsed_module_cache_entry) =
  {
    cached_path = entry.parsed_path;
    cached_origin = entry.parsed_origin;
    cached_decls = entry.parsed_decls;
    cached_exports = entry.parsed_exports;
    cached_surface = entry.parsed_surface;
  }

let resolved_origin_equal left right =
  match (left, right) with
  | Session.Stdlib_module, Session.Stdlib_module -> true
  | Session.User_module, Session.User_module -> true
  | Session.Package_module left_id, Session.Package_module right_id
  | ( Session.Native_package_module left_id,
      Session.Native_package_module right_id ) ->
      Session.package_id_name left_id = Session.package_id_name right_id
  | ( ( Session.Stdlib_module | Session.User_module | Session.Package_module _
      | Session.Native_package_module _ ),
      _ ) ->
      false

type cached_parse_result =
  | Cached_current of cached_module_source
  | Cached_changed_source of string

let cached_filesystem_entry_is_current ~sess ~base_dir ~module_name
    (entry : Session.parsed_module_cache_entry) =
  match resolve_module_file ~sess base_dir module_name with
  | None -> None
  | Some resolved
    when resolved.resolved_path <> entry.parsed_path
         || not
              (resolved_origin_equal resolved.resolved_origin
                 entry.parsed_origin) ->
      None
  | Some _ -> (
      match read_file entry.parsed_path with
      | exception Sys_error _ -> None
      | source ->
          if source_hash source = entry.parsed_source_hash then
            Some (Cached_current (cached_module_source_of_entry entry))
          else Some (Cached_changed_source source))

let cached_entry_resolution_matches ~sess ~base_dir ~module_name
    (entry : Session.parsed_module_cache_entry) =
  match resolve_module_file ~sess base_dir module_name with
  | None -> false
  | Some resolved ->
      resolved.resolved_path = entry.parsed_path
      && resolved_origin_equal resolved.resolved_origin entry.parsed_origin

let cached_parse_entry ~sess ~base_dir ~module_name
    (entry : Session.parsed_module_cache_entry) =
  if
    embedded_module_path entry.parsed_path
    && not sess.Session.std_override_active
  then Some (Cached_current (cached_module_source_of_entry entry))
  else if entry.parsed_trust_current_source then
    if cached_entry_resolution_matches ~sess ~base_dir ~module_name entry then
      Some (Cached_current (cached_module_source_of_entry entry))
    else None
  else cached_filesystem_entry_is_current ~sess ~base_dir ~module_name entry

(** Extract export names from a single declaration (inner decl_desc).
    Returns a list of (name, decl) pairs. *)
let extract_export_names _decl inner_decl =
  match inner_decl.decl_desc with
  | DFunc f -> (
      match f.func_name with Some n -> [ (n, inner_decl) ] | None -> [])
  | DVar v -> (
      match v.var_name with Some n -> [ (n, inner_decl) ] | None -> [])
  | DType t -> [ (t.type_name, inner_decl) ]
  | DRecord r -> [ (r.record_name, inner_decl) ]
  | DTypeAlias a -> [ (a.alias_name, inner_decl) ]
  | DTrait t ->
      (* Export both the trait name and its method names:
         - [traits: Equatable] imports the trait and exposes all of its
           bare methods.
         - [traits: equals] imports just that method as a bare trait function.
         Alias-only module imports still expose neither; typecheck decides
         bare visibility from the import shape. *)
      (t.trait_name, inner_decl)
      :: List.map (fun meth -> (meth.method_name, inner_decl)) t.trait_methods
  | DImpl impl ->
      (* Extract each method from the impl as a separate export *)
      List.filter_map
        (fun func ->
          Option.map
            (fun name -> (name, { inner_decl with decl_desc = DFunc func }))
            func.func_name)
        impl.impl_methods
  | DImport _ | DPrivate _ -> []

(** Collect exported declarations from a program.
    All top-level declarations are exported by default, except:
    - DPrivate: explicitly excluded
    - DImport: module-internal, not re-exported *)
let collect_exports decls =
  let private_traits =
    List.filter_map
      (fun d ->
        match d.decl_desc with
        | DPrivate { decl_desc = DTrait t; _ } -> Some t.trait_name
        | _ -> None)
      decls
  in
  List.concat_map
    (fun decl ->
      match decl.decl_desc with
      | DPrivate _ -> []
      | DImport _ -> []
      | DImpl impl when List.mem impl.impl_trait private_traits -> []
      | _ -> extract_export_names decl decl)
    decls

let exported_func_is_debug_only module_path func_name =
  match Hashtbl.find_opt (sess_of ()).module_cache module_path with
  | None -> false
  | Some m ->
      let exports =
        match get_typed_decls m.name with
        | Some typed -> collect_exports (Typed_ast.program_ast typed)
        | None -> m.exports
      in
      List.exists
        (fun (name, decl) ->
          name = func_name
          &&
          match decl.decl_desc with
          | DFunc func -> func.func_debug_only
          | _ -> false)
        exports

(** Collect names of private declarations (for better error messages). *)
let collect_private_names decls =
  List.concat_map
    (fun decl ->
      match decl.decl_desc with
      | DPrivate inner -> extract_export_names decl inner
      | _ -> [])
    decls

let private_names_for_import_diagnostics (m : loaded_module) =
  match m.surface with
  | Some surface -> Module_surface.private_names_as_ast_pairs m.decls surface
  | None -> collect_private_names m.decls

(** Suggest a similar export name for typo correction.
    Uses simple Levenshtein-like matching on module exports. *)
let suggest_export (m : loaded_module) (name : string) : string option =
  let exports = List.map fst m.exports in
  let name_lower = String.lowercase_ascii name in
  let best =
    List.fold_left
      (fun acc exp ->
        let exp_lower = String.lowercase_ascii exp in
        (* Simple edit distance: same length, differ by 1-2 chars *)
        let nlen = String.length name_lower
        and elen = String.length exp_lower in
        if abs (nlen - elen) > 2 || nlen < 3 then acc
        else
          let diffs = ref 0 in
          let min_len = min nlen elen in
          for i = 0 to min_len - 1 do
            if name_lower.[i] <> exp_lower.[i] then incr diffs
          done;
          diffs := !diffs + abs (nlen - elen);
          if
            !diffs <= 2
            && (acc = None
               || !diffs < match acc with Some (_, d) -> d | None -> 999)
          then Some (exp, !diffs)
          else acc)
      None exports
  in
  match best with
  | Some (suggestion, _) ->
      Some (Printf.sprintf "Did you mean '%s'?" suggestion)
  | None -> None

let std_module_available ~(sess : Session.t) ~base_dir module_name =
  has_prefix "std/" module_name
  && ((not sess.std_override_active)
      && Option.is_some (Embedded_std.find module_name)
     ||
     match resolve_module_path ~sess base_dir module_name with
     | Some path -> is_std_source_file ~sess path
     | None -> false)

let record_module_parse_message ~(sess : Session.t) ~path ~line ~col msg =
  (* Collect into the session's [load_errors] list so the pipeline can surface
     parse failures through the normal diagnostic channel. The parser must not
     print directly to stderr — that bypasses formatting and breaks structured
     error consumers. *)
  let file_msg = Printf.sprintf "%s\n   --> %s:%d:%d" msg path line col in
  let err =
    {
      Ast.message = file_msg;
      loc = Ast.point_loc_in ~file:path ~line ~column:col;
      phase = Ast.ModuleLoad;
      kind = Ast.OtherError;
      notes = [];
      help = None;
    }
  in
  sess.Session.load_errors <- err :: sess.load_errors

let exports_for_cached_source decls = function
  | Some surface -> Module_surface.exports_as_ast_pairs decls surface
  | None -> collect_exports decls

let cache_parsed_module_source ?(trust_current_source = false) ?surface
    ~(sess : Session.t) ~module_name ~path ~origin ~source decls =
  match
    Option.map (Module_surface.validate_against_program decls) surface
  with
  | Some (Error message) ->
      record_module_parse_message ~sess ~path ~line:1 ~col:1
        ("invalid module surface from parser bridge: " ^ message);
      None
  | None | Some (Ok ()) ->
      let exports = exports_for_cached_source decls surface in
      let entry : Session.parsed_module_cache_entry =
        {
          parsed_path = path;
          parsed_origin = origin;
          parsed_source_hash = source_hash source;
          parsed_trust_current_source = trust_current_source;
          parsed_decls = decls;
          parsed_exports = exports;
          parsed_surface = surface;
        }
      in
      Hashtbl.replace sess.parse_cache module_name entry;
      Some
        {
          cached_path = path;
          cached_origin = origin;
          cached_decls = decls;
          cached_exports = exports;
          cached_surface = surface;
        }

let preload_parsed_sources ?sess sources =
  let sess = sess_of ?sess () in
  List.iter
    (fun source ->
      ignore
        (cache_parsed_module_source ~trust_current_source:true ~sess
           ~module_name:source.preload_module_name ~path:source.preload_path
           ~origin:source.preload_origin ~source:source.preload_source
           ?surface:source.preload_surface
           source.preload_decls))
    sources

type module_parse_batch_item = {
  module_parse_name : string;
  module_parse_path : string;
  module_parse_origin : Session.module_origin;
  module_parse_source : string;
}

type module_preload_candidate = {
  preload_module_name : string;
  preload_base_dir : string;
}

type module_parse_preload_result = {
  preload_failed_modules : string list;
  preload_cached_items : module_parse_batch_item list;
}

let empty_module_parse_preload_result =
  { preload_failed_modules = []; preload_cached_items = [] }

(* Batch enough small modules to avoid process overhead, but cap source bytes
   so generated AST JSON for large compiler-owned modules does not turn one
   bridge request into a long-running memory-heavy response. *)
let module_parse_batch_max_items = 64
let module_parse_batch_max_source_bytes = 256 * 1024

let combine_module_parse_preload_results left right =
  {
    preload_failed_modules =
      List.rev_append left.preload_failed_modules right.preload_failed_modules;
    preload_cached_items =
      List.rev_append left.preload_cached_items right.preload_cached_items;
  }

let fresh_module_parse_batch_item ~(sess : Session.t) ~base_dir module_name =
  let from_embedded =
    if has_prefix "std/" module_name && not sess.std_override_active then
      match Embedded_std.find module_name with
      | Some source ->
          Some
            {
              module_parse_name = module_name;
              module_parse_path = Printf.sprintf "<embedded:%s>" module_name;
              module_parse_origin = Session.Stdlib_module;
              module_parse_source = source;
            }
      | None -> None
    else None
  in
  match from_embedded with
  | Some _ as item -> item
  | None -> (
      match resolve_module_file ~sess base_dir module_name with
      | None -> None
      | Some resolved -> (
          match read_file resolved.resolved_path with
          | exception Sys_error _ -> None
          | source ->
              Some
                {
                  module_parse_name = module_name;
                  module_parse_path = resolved.resolved_path;
                  module_parse_origin = resolved.resolved_origin;
                  module_parse_source = source;
                }))

let module_parse_batch_item ~(sess : Session.t) ~base_dir module_name =
  if Hashtbl.mem sess.module_cache module_name then None
  else
    match Hashtbl.find_opt sess.parse_cache module_name with
    | Some entry -> (
        match cached_parse_entry ~sess ~base_dir ~module_name entry with
        | Some (Cached_current _) -> None
        | Some (Cached_changed_source source) ->
            Hashtbl.remove sess.parse_cache module_name;
            Some
              {
                module_parse_name = module_name;
                module_parse_path = entry.parsed_path;
                module_parse_origin = entry.parsed_origin;
                module_parse_source = source;
              }
        | None ->
            Hashtbl.remove sess.parse_cache module_name;
            fresh_module_parse_batch_item ~sess ~base_dir module_name)
    | None -> fresh_module_parse_batch_item ~sess ~base_dir module_name

let bridge_batch_request_of_module_parse item :
    Compiler_blorp_bridge.parse_source_batch_request =
  {
    Compiler_blorp_bridge.batch_parse_path = item.module_parse_path;
    batch_parse_module_name = item.module_parse_name;
    batch_parse_text = item.module_parse_source;
  }

type module_parse_apply_result =
  | ModuleParseCached of module_parse_batch_item
  | ModuleParseFailed of string

let apply_module_parse_batch_response ~(sess : Session.t) item response =
  let {
    Compiler_blorp_bridge.batch_parsed_path;
    batch_parsed_module_name;
    batch_parsed_response;
  } =
    response
  in
  if
    batch_parsed_path <> item.module_parse_path
    || batch_parsed_module_name <> item.module_parse_name
  then (
    record_module_parse_message ~sess ~path:item.module_parse_path ~line:1
      ~col:1
      (Printf.sprintf
         "Blorp parser bridge returned artifact for '%s' at '%s' while parsing \
          '%s' at '%s'"
         batch_parsed_module_name batch_parsed_path item.module_parse_name
         item.module_parse_path);
    ModuleParseFailed item.module_parse_name)
  else
    match batch_parsed_response with
    | Compiler_blorp_bridge.ParseSourceDiagnostics diagnostics ->
        sess.load_errors <- List.rev_append diagnostics sess.load_errors;
        ModuleParseFailed item.module_parse_name
    | Compiler_blorp_bridge.ParsedSource parsed_source -> (
        match
          cache_parsed_module_source ~sess ~module_name:item.module_parse_name
            ~path:item.module_parse_path ~origin:item.module_parse_origin
            ~source:item.module_parse_source
            ?surface:parsed_source.parsed_module_surface
            parsed_source.parsed_program
        with
        | Some _ -> ModuleParseCached item
        | None -> ModuleParseFailed item.module_parse_name)

let apply_module_parse_batch_responses ~(sess : Session.t) items responses =
  let rec loop result items responses =
    match (items, responses) with
    | [], [] -> result
    | item :: rest_items, response :: rest_responses -> (
        match apply_module_parse_batch_response ~sess item response with
        | ModuleParseFailed failed_module ->
            loop
              {
                result with
                preload_failed_modules =
                  failed_module :: result.preload_failed_modules;
              }
              rest_items rest_responses
        | ModuleParseCached cached_item ->
            loop
              {
                result with
                preload_cached_items = cached_item :: result.preload_cached_items;
              }
              rest_items rest_responses)
    | _ -> result
  in
  loop empty_module_parse_preload_result items responses

let module_parse_batch_chunks items =
  let item_source_bytes item = String.length item.module_parse_source in
  let flush chunks chunk =
    match chunk with
    | [] -> chunks
    | _ -> List.rev chunk :: chunks
  in
  let rec loop chunks chunk chunk_items chunk_bytes = function
    | [] -> List.rev (flush chunks chunk)
    | item :: rest ->
        let item_bytes = item_source_bytes item in
        let exceeds_count = chunk_items >= module_parse_batch_max_items in
        let exceeds_bytes =
          chunk <> []
          && chunk_bytes + item_bytes > module_parse_batch_max_source_bytes
        in
        if exceeds_count || exceeds_bytes then
          loop (flush chunks chunk) [ item ] 1 item_bytes rest
        else
          loop chunks (item :: chunk) (chunk_items + 1)
            (chunk_bytes + item_bytes) rest
  in
  loop [] [] 0 0 items

let preload_module_parse_cache_chunk_with_blorp_bridge ~(sess : Session.t) items
    =
  match items with
  | [] -> empty_module_parse_preload_result
  | _ -> (
      let requests = List.map bridge_batch_request_of_module_parse items in
      match
        Compiler_blorp_bridge.parse_sources_via_command
          ~phase:Compiler_blorp_bridge.TypecheckSourceProgram requests
      with
      | Error _ -> empty_module_parse_preload_result
      | Ok responses ->
          if List.length responses <> List.length items then
            empty_module_parse_preload_result
          else apply_module_parse_batch_responses ~sess items responses)

let preload_module_parse_cache_with_blorp_bridge ~(sess : Session.t) items =
  items |> module_parse_batch_chunks
  |> List.fold_left
       (fun acc chunk ->
         combine_module_parse_preload_results acc
           (preload_module_parse_cache_chunk_with_blorp_bridge ~sess chunk))
       empty_module_parse_preload_result

let std_support_module_name name =
  if has_prefix "std/" name then name else "std/" ^ name

let canonical_module_name_for_preload ~(sess : Session.t) ~base_dir module_name =
  let is_relative =
    has_prefix "./" module_name || has_prefix "../" module_name
  in
  let is_bare =
    (not (has_prefix "std/" module_name))
    && (not (has_prefix "pkg/" module_name))
    && not is_relative
  in
  let bare_std_name = "std/" ^ module_name in
  if
    is_bare
    && (Hashtbl.mem sess.module_cache bare_std_name
       || std_module_available ~sess ~base_dir bare_std_name)
  then bare_std_name
  else module_name

let module_preload_candidate ~base_dir module_name =
  { preload_module_name = module_name; preload_base_dir = base_dir }

let import_module_names_from_decls decls =
  decls
  |> List.filter_map (fun decl ->
         match decl.decl_desc with
         | DImport imp -> Some imp.import_module
         | _ -> None)

let module_import_names ?surface decls =
  match surface with
  | Some surface -> Module_surface.import_module_names surface
  | None -> import_module_names_from_decls decls

let module_parse_import_base_dir ~fallback_base_dir item =
  if embedded_module_path item.module_parse_path then fallback_base_dir
  else extract_directory item.module_parse_path

let module_preload_candidate_key candidate =
  candidate.preload_base_dir ^ "\000" ^ candidate.preload_module_name

let add_module_preload_candidate ~(sess : Session.t) seen candidate acc =
  let module_name =
    canonical_module_name_for_preload ~sess
      ~base_dir:candidate.preload_base_dir candidate.preload_module_name
  in
  let candidate = { candidate with preload_module_name = module_name } in
  let key = module_preload_candidate_key candidate in
  if Hashtbl.mem seen key then acc
  else begin
    Hashtbl.add seen key ();
    candidate :: acc
  end

let import_candidates_from_cached_item ~(sess : Session.t) ~fallback_base_dir
    seen item acc =
  match Hashtbl.find_opt sess.parse_cache item.module_parse_name with
  | None -> acc
  | Some entry ->
      let import_base_dir =
        module_parse_import_base_dir ~fallback_base_dir item
      in
      module_import_names ?surface:entry.parsed_surface entry.parsed_decls
      |> List.fold_left
           (fun acc module_name ->
             add_module_preload_candidate ~sess seen
               (module_preload_candidate ~base_dir:import_base_dir module_name)
               acc)
           acc

let preload_module_import_closure ~(sess : Session.t) ~base_dir candidates =
  let seen = Hashtbl.create 32 in
  let initial =
    List.fold_left
      (fun acc candidate -> add_module_preload_candidate ~sess seen candidate acc)
      [] candidates
    |> List.rev
  in
  let rec loop failed pending =
    match pending with
    | [] -> failed
    | _ ->
        let items =
          pending
          |> List.filter_map (fun candidate ->
                 module_parse_batch_item ~sess
                   ~base_dir:candidate.preload_base_dir
                   candidate.preload_module_name)
        in
        let result = preload_module_parse_cache_with_blorp_bridge ~sess items in
        let next =
          List.fold_left
            (fun acc item ->
              import_candidates_from_cached_item ~sess ~fallback_base_dir:base_dir
                seen item acc)
            [] result.preload_cached_items
          |> List.rev
        in
        loop (List.rev_append result.preload_failed_modules failed) next
  in
  loop [] initial

let eager_typecheck_support_candidates base_dir =
  eager_typecheck_support_modules
  |> List.map (fun module_name ->
         module_preload_candidate ~base_dir
           (std_support_module_name module_name))

let import_preload_candidates ?surface base_dir decls =
  decls |> module_import_names ?surface
  |> List.map (module_preload_candidate ~base_dir)

(** Load a module by name
    @param module_name Module name like "std/List"
    @param base_dir Directory of the importing file
    @return Some(module) if successful, None otherwise
*)
let rec load_module ?sess module_name base_dir =
  let sess = sess_of ?sess () in
  let is_relative =
    has_prefix "./" module_name || has_prefix "../" module_name
  in
  (* Bare imports (no std/, ./, ../ prefix) resolve to std/ canonical name *)
  let is_bare =
    (not (has_prefix "std/" module_name))
    && (not (has_prefix "pkg/" module_name))
    && not is_relative
  in
  let bare_std_name = "std/" ^ module_name in
  let bare_resolves_to_std =
    is_bare
    && (Hashtbl.mem sess.module_cache bare_std_name
       || std_module_available ~sess ~base_dir bare_std_name)
  in
  let local_path_alias =
    if is_relative || (is_bare && not bare_resolves_to_std) then
      resolve_module_path ~sess base_dir module_name
    else None
  in
  let load_bare_or_direct () =
    if is_bare then
      (* Bare names prefer std modules only when a std module is known to
         exist. The availability check is side-effect free: a failed std
         probe must not leave diagnostics behind when a local module of the
         same bare name exists. *)
      match Hashtbl.find_opt sess.module_cache bare_std_name with
      | Some m ->
          Hashtbl.replace sess.module_cache module_name m;
          Some m
      | None ->
          if bare_resolves_to_std then
            match load_module_inner ~sess bare_std_name base_dir with
            | Some m ->
                Hashtbl.replace sess.module_cache module_name m;
                Some m
            | None -> None
          else load_module_inner ~sess module_name base_dir
    else load_module_inner ~sess module_name base_dir
  in
  let discard_stale_local_alias resolved_path =
    (match Hashtbl.find_opt sess.module_cache module_name with
    | Some m when m.path <> resolved_path ->
        Hashtbl.remove sess.module_cache module_name
    | _ -> ());
    match Hashtbl.find_opt sess.parse_cache module_name with
    | Some entry when entry.parsed_path <> resolved_path ->
        Hashtbl.remove sess.parse_cache module_name
    | _ -> ()
  in
  match local_path_alias with
  | Some resolved_path -> (
      match find_cached_by_path sess resolved_path with
      | Some m ->
          Hashtbl.replace sess.module_cache module_name m;
          Some m
      | None -> (
          discard_stale_local_alias resolved_path;
          match load_bare_or_direct () with
          | Some m ->
              Hashtbl.replace sess.module_cache resolved_path m;
              Hashtbl.replace sess.module_cache module_name m;
              Some m
          | None -> None))
  | None -> (
      match Hashtbl.find_opt sess.module_cache module_name with
      | Some m -> Some m
      | None -> load_bare_or_direct ())

(** Parse source text for a module, caching the result.
    Shared by embedded and filesystem module loading. *)
and parse_module_source ~(sess : Session.t) ~module_name ~path ~origin source =
  match
    parse_source_artifact_with_blorp_bridge ~path ~module_name
      ~phase:Compiler_blorp_bridge.TypecheckSourceProgram
      ~bridge_read_file:(not (embedded_module_path path)) source
  with
  | Ok parsed_source ->
      cache_parsed_module_source ~sess ~module_name ~path ~origin ~source
        ?surface:parsed_source.parsed_module_surface
        parsed_source.parsed_program
  | Error (BridgeParseCompilerErrors errors) ->
      sess.load_errors <- List.rev_append errors sess.load_errors;
      None
  | Error (BridgeParseMessage message) ->
      record_module_parse_message ~sess ~path ~line:1 ~col:1 message;
      None

and load_module_inner ~(sess : Session.t) module_name base_dir =
  match Hashtbl.find_opt sess.Session.module_cache module_name with
  | Some m -> Some m
  | None -> (
      let parse_fresh () =
        let from_embedded =
          if has_prefix "std/" module_name && not sess.std_override_active then
            match Embedded_std.find module_name with
            | Some source ->
                let path = Printf.sprintf "<embedded:%s>" module_name in
                parse_module_source ~sess ~module_name ~path
                  ~origin:Session.Stdlib_module source
            | None -> None
          else None
        in
        match from_embedded with
        | Some _ -> from_embedded
        | None -> (
            (* Fall back to filesystem resolution. For std modules, this
               only succeeds when an explicit std override is active. *)
            match resolve_module_file ~sess base_dir module_name with
            | None ->
                let msg =
                  if has_prefix "std/" module_name then
                    begin if sess.std_override_active then
                      let dir =
                        match sess.std_override_dir with
                        | Some d -> d
                        | None -> "<unknown>"
                      in
                      Printf.sprintf
                        "Could not find module '%s'\n\
                        \  = note: the standard library override is set to \
                         '%s' but '%s.brp' was not found\n\
                        \  = help: Check --std-dir, BLORP_STD, or blorp.toml; \
                         remove the override to use the embedded standard \
                         library"
                        module_name dir
                        (strip_prefix "std/" module_name)
                    else
                      (* Build the "available std modules" list from
                         [Embedded_std.modules] so it stays in sync
                         automatically as modules are added/removed. *)
                      let available =
                        Embedded_std.modules
                        |> List.filter_map (fun (name, _) ->
                            if has_prefix "std/" name then
                              Some (strip_prefix "std/" name)
                            else None)
                        |> List.sort String.compare |> String.concat ", "
                      in
                      Printf.sprintf
                        "Unknown standard library module '%s'\n\
                        \  = help: Available std modules: %s"
                        module_name available
                    end
                  else if has_prefix "pkg/" module_name then
                    if
                      match sess.std_source_dir with
                      | Some std_dir -> is_path_under_dir ~dir:std_dir base_dir
                      | None -> false
                    then
                      "standard library modules cannot import package modules"
                    else if
                      Option.is_some (source_package_for_base_dir sess base_dir)
                    then "source packages cannot import pkg/... modules"
                    else
                      let roots =
                        match List.rev sess.package_roots with
                        | [] -> "<none>"
                        | roots -> String.concat ", " roots
                      in
                      Printf.sprintf
                        "Could not find package module '%s'\n\
                        \  = help: Package imports resolve only from local \
                         package roots. Create %s.brp under a local pkg/ \
                         directory or add a package root.\n\
                        \  Package roots: %s"
                        module_name module_name roots
                  else
                    match source_package_for_base_dir sess base_dir with
                    | Some current_pkg -> (
                        match
                          source_package_alias_for_module sess module_name
                        with
                        | Some other_pkg
                          when other_pkg.source_package_alias
                               <> current_pkg.source_package_alias ->
                            Printf.sprintf
                              "source packages cannot import other package \
                               aliases; package %S tried to import alias %S"
                              current_pkg.source_package_alias
                              other_pkg.source_package_alias
                        | _ ->
                            Printf.sprintf
                              "source packages may import only std modules or \
                               modules inside their own package; package %S \
                               tried to import %S"
                              current_pkg.source_package_alias module_name)
                    | None -> (
                        match
                          source_package_alias_load_error sess module_name
                        with
                        | Some msg -> msg
                        | None ->
                            let suggestion =
                              let lower = String.lowercase_ascii module_name in
                              if lower <> module_name then
                                match
                                  resolve_module_path ~sess base_dir lower
                                with
                                | Some _ ->
                                    Printf.sprintf " (did you mean '%s'?)" lower
                                | None -> ""
                              else ""
                            in
                            Printf.sprintf
                              "Could not find module '%s'%s\n  Search paths: %s"
                              module_name suggestion
                              (String.concat ", " sess.search_paths))
                in
                let err =
                  {
                    Ast.message = msg;
                    loc = Ast.dummy_loc;
                    phase = Ast.ModuleLoad;
                    kind = Ast.OtherError;
                    notes = [];
                    help = None;
                  }
                in
                sess.load_errors <- err :: sess.load_errors;
                None
            | Some resolved ->
                let path = resolved.resolved_path in
                let source = read_file path in
                let origin = resolved.resolved_origin in
                parse_module_source ~sess ~module_name ~path ~origin source)
      in
      (* Try parse cache first. Filesystem-backed entries validate the current
         source hash before reuse; stale/moved entries fall through to a fresh
         resolve+parse. *)
      let parsed =
        match Hashtbl.find_opt sess.parse_cache module_name with
        | Some entry -> (
            match cached_parse_entry ~sess ~base_dir ~module_name entry with
            | Some (Cached_current parsed) -> Some parsed
            | Some (Cached_changed_source source) ->
                Hashtbl.remove sess.parse_cache module_name;
                parse_module_source ~sess ~module_name ~path:entry.parsed_path
                  ~origin:entry.parsed_origin source
            | None ->
                Hashtbl.remove sess.parse_cache module_name;
                parse_fresh ())
        | None -> parse_fresh ()
      in
      match parsed with
      | None -> None
      | Some { cached_path; cached_origin; cached_decls; cached_exports; cached_surface } ->
          (* Create module and add to active cache *)
          let m =
            {
              name = module_name;
              path = cached_path;
              origin = cached_origin;
              decls = cached_decls;
              exports = cached_exports;
              surface = cached_surface;
              typed_decls = None;
              typed_import_bindings = None;
            }
          in
          Hashtbl.add sess.module_cache module_name m;
          (* Register public trait defs into the session-scoped trait
             index. This is what makes supertrait-chain resolution
             uniform across all loaded traits (stdlib AND user modules),
             independent of whether the consuming file imports the
             trait's home module. See [Session.trait_index]. *)
          Session.register_module_traits sess m;
          (* Same pattern for types: register every DType/DRecord into
             [sess.type_index] so cross-module diagnostics can qualify
             constructor and type references (Track B). *)
          Session.register_module_types sess m;
          (* Recursively load this module's imports into active cache *)
          let module_dir = extract_directory cached_path in
          let _ = load_imports ~sess ?surface:cached_surface cached_decls module_dir in
          Some m)

(** Load all imports from a list of declarations.
    Ensures prelude modules (option, result) are loaded on first call,
    since their type definitions are needed by codegen for any program
    that uses these prelude types without explicit imports. *)
and load_imports ?sess ?surface decls base_dir =
  let sess = sess_of ?sess () in
  let import_names = module_import_names ?surface decls in
  let preload_candidates =
    if not sess.prelude_modules_loaded then
      eager_typecheck_support_candidates base_dir
      @ import_preload_candidates ?surface base_dir decls
    else import_preload_candidates ?surface base_dir decls
  in
  let failed_preloaded_modules =
    preload_module_import_closure ~sess ~base_dir preload_candidates
  in
  if not sess.prelude_modules_loaded then begin
    sess.prelude_modules_loaded <- true;
    List.iter
      (fun m ->
        let canonical_name = std_support_module_name m in
        if not (List.mem canonical_name failed_preloaded_modules) then
          ignore (load_module ~sess m base_dir))
      eager_typecheck_support_modules
  end;
  List.filter_map
    (fun import_module ->
      let canonical_name =
        canonical_module_name_for_preload ~sess ~base_dir import_module
      in
      if List.mem canonical_name failed_preloaded_modules then None
      else load_module ~sess import_module base_dir)
    import_names

let record_graph_load_error ~(sess : Session.t) ~path message =
  let err =
    {
      Ast.message;
      loc = Ast.point_loc_in ~file:path ~line:1 ~column:1;
      phase = Ast.ModuleLoad;
      kind = Ast.OtherError;
      notes = [];
      help = None;
    }
  in
  sess.load_errors <- err :: sess.load_errors

let apply_preloaded_module_graph_context ~(sess : Session.t)
    (context : preloaded_module_graph_context) =
  Option.iter (set_std_override ~sess) context.preload_graph_std_dir;
  List.iter (add_source_package ~sess) context.preload_graph_source_packages;
  List.iter (add_package_root ~sess) context.preload_graph_package_roots;
  add_search_path ~sess (Sys.getcwd ())

let preloaded_source_key path module_name = path ^ "\000" ^ module_name

let find_preloaded_source (sources : preloaded_parsed_source list) path
    module_name =
  List.find_opt
    (fun source ->
      source.preload_path = path && source.preload_module_name = module_name)
    sources

let preloaded_sources_for_path (sources : preloaded_parsed_source list) path =
  List.filter (fun source -> source.preload_path = path) sources

let load_preloaded_source_module ~(sess : Session.t)
    (source : preloaded_parsed_source) =
  match Hashtbl.find_opt sess.module_cache source.preload_module_name with
  | Some _ -> ()
  | None -> (
      match find_cached_by_path sess source.preload_path with
      | Some m ->
          Hashtbl.replace sess.module_cache source.preload_module_name m
      | None -> (
          match
            cache_parsed_module_source ~trust_current_source:true ~sess
              ~module_name:source.preload_module_name ~path:source.preload_path
              ~origin:source.preload_origin ~source:source.preload_source
              ?surface:source.preload_surface
              source.preload_decls
          with
          | None -> ()
          | Some
              {
                cached_path;
                cached_origin;
                cached_decls;
                cached_exports;
                cached_surface;
              } ->
              let m =
                {
                  name = source.preload_module_name;
                  path = cached_path;
                  origin = cached_origin;
                  decls = cached_decls;
                  exports = cached_exports;
                  surface = cached_surface;
                  typed_decls = None;
                  typed_import_bindings = None;
                }
              in
              Hashtbl.replace sess.module_cache source.preload_module_name m;
              Session.register_module_traits sess m;
              Session.register_module_types sess m))

let embedded_std_load_name_for_graph_import ~(sess : Session.t) import_path =
  if sess.std_override_active then None
  else if has_prefix "std/" import_path then
    Option.map (fun _ -> import_path) (Embedded_std.find import_path)
  else
    let is_relative =
      has_prefix "./" import_path || has_prefix "../" import_path
    in
    let is_bare =
      (not (has_prefix "pkg/" import_path)) && not is_relative
    in
    if is_bare then
      let std_name = "std/" ^ import_path in
      Option.map (fun _ -> import_path) (Embedded_std.find std_name)
    else None

let graph_unresolved_import_message ~(sess : Session.t) ~base_dir import_path =
  match source_package_alias_load_error sess import_path with
  | Some message -> message
  | None when has_prefix "pkg/" import_path ->
      let roots =
        match List.rev sess.package_roots with
        | [] -> "<none>"
        | roots -> String.concat ", " roots
      in
      Printf.sprintf
        "Could not find package module '%s'\n\
        \  = help: Package imports resolve only from local package roots. \
         Create %s.brp under a local pkg/ directory or add a package root.\n\
        \  Package roots: %s"
        import_path import_path roots
  | None -> (
      match source_package_for_base_dir sess base_dir with
      | Some current_pkg ->
          Printf.sprintf
            "source packages may import only std modules or modules inside \
             their own package; package %S tried to import %S"
            current_pkg.source_package_alias import_path
      | None ->
          Printf.sprintf "Could not find module '%s'\n  Search paths: %s"
            import_path
            (String.concat ", " sess.search_paths))

let graph_edges_from graph path module_name =
  List.filter
    (fun edge ->
      edge.preload_import_from_path = path
      && edge.preload_import_from_module = module_name)
    graph.preload_graph_imports

let cache_preloaded_graph_import_alias ~(sess : Session.t) ~import_path
    ~resolved_module =
  if import_path <> resolved_module then
    match Hashtbl.find_opt sess.module_cache resolved_module with
    | Some m -> Hashtbl.replace sess.module_cache import_path m
    | None -> ()

let load_preloaded_graph_std_support ~(sess : Session.t) base_dir =
  if not sess.prelude_modules_loaded then begin
    sess.prelude_modules_loaded <- true;
    List.iter
      (fun module_name ->
        ignore (load_module ~sess module_name base_dir))
      eager_typecheck_support_modules
  end

let load_preloaded_module_graph ?sess ~target_path graph =
  let sess = sess_of ?sess () in
  apply_preloaded_module_graph_context ~sess graph.preload_graph_context;
  let target_base_dir = extract_directory target_path in
  load_preloaded_graph_std_support ~sess target_base_dir;
  let visited = Hashtbl.create 32 in
  let rec visit_source ~load_current path module_name =
    let key = preloaded_source_key path module_name in
    if not (Hashtbl.mem visited key) then begin
      Hashtbl.add visited key ();
      match find_preloaded_source graph.preload_graph_sources path module_name with
      | None ->
          record_graph_load_error ~sess ~path
            (Printf.sprintf
               "frontend module graph referenced `%s` at `%s`, but that \
                source was not supplied"
               module_name path)
      | Some source ->
          if load_current then load_preloaded_source_module ~sess source;
          let base_dir = extract_directory source.preload_path in
          graph_edges_from graph source.preload_path source.preload_module_name
          |> List.iter (fun edge ->
                 match
                   ( edge.preload_import_resolved_path,
                     edge.preload_import_resolved_module )
                 with
                 | Some resolved_path, Some resolved_module ->
                     visit_source ~load_current:true resolved_path
                       resolved_module;
                     cache_preloaded_graph_import_alias ~sess
                       ~import_path:edge.preload_import_path ~resolved_module
                 | None, None -> (
                     match
                       embedded_std_load_name_for_graph_import ~sess
                         edge.preload_import_path
                     with
                     | Some load_name ->
                         ignore (load_module ~sess load_name base_dir)
                     | None ->
                         record_graph_load_error ~sess ~path:source.preload_path
                           (graph_unresolved_import_message ~sess ~base_dir
                              edge.preload_import_path))
                 | _ ->
                     record_graph_load_error ~sess ~path:source.preload_path
                       "frontend module graph import edge had an incomplete \
                        resolved target")
    end
  in
  match preloaded_sources_for_path graph.preload_graph_sources target_path with
  | [] ->
      record_graph_load_error ~sess ~path:target_path
        "frontend module graph did not contain the target source"
  | roots ->
      List.iter
        (fun root ->
          visit_source ~load_current:false root.preload_path
            root.preload_module_name)
        roots

(** Get module dependencies (names of modules it imports) *)
let get_dependencies m =
  module_import_names ?surface:m.surface m.decls

(** Prelude modules whose type definitions must be emitted before all others.
    These are auto-loaded by load_imports and must come first in the codegen
    order since any module may use Option/Result without an explicit import. *)
let prelude_module_names = [ "std/bool"; "std/option"; "std/result" ]

(** Get all loaded modules in dependency order (topological sort).
    Prelude modules (option, result) are always placed first, since their
    type definitions are needed by any module that uses prelude types.
    Other modules follow in dependency order. *)
let get_all_modules ?sess () =
  let sess = sess_of ?sess () in
  let all = Hashtbl.fold (fun _ m acc -> m :: acc) sess.module_cache [] in
  let visited = Hashtbl.create 16 in
  let result = ref [] in
  let rec visit name =
    match Hashtbl.find_opt sess.module_cache name with
    | Some m ->
        if not (Hashtbl.mem visited m.name) then begin
          Hashtbl.add visited m.name true;
          List.iter visit (get_dependencies m);
          result := m :: !result
        end
    | None -> ()
  in
  (* Visit prelude modules first to ensure their type definitions are emitted
     before any module that uses Option/Result types *)
  List.iter visit prelude_module_names;
  List.iter (fun m -> visit m.name) all;
  List.rev !result

let prune_parse_cache_to_loaded_modules ?sess () =
  let sess = sess_of ?sess () in
  let active = Hashtbl.create 16 in
  Hashtbl.iter
    (fun _ (m : loaded_module) -> Hashtbl.replace active m.name ())
    sess.module_cache;
  let stale = ref [] in
  Hashtbl.iter
    (fun module_name (entry : Session.parsed_module_cache_entry) ->
      if
        (not (Session.module_origin_is_std entry.parsed_origin))
        && not (Hashtbl.mem active module_name)
      then stale := module_name :: !stale)
    sess.parse_cache;
  List.iter
    (fun module_name -> Hashtbl.remove sess.parse_cache module_name)
    !stale

(** Look up a module in the cache by name *)
let find_cached ?sess name =
  Hashtbl.find_opt (sess_of ?sess ()).module_cache name

(** Reset the active module graph between compilations.
    Clears the module cache (typed ASTs go with it) but preserves the parse
    cache to avoid re-parsing std library modules.

    Prefer [Session.create ()] for full isolation. This is kept as a
    compatibility shim for the pipeline which historically resets in
    place; future work can migrate those call sites to create a new
    session instead. *)
let reset ?sess () =
  let sess = sess_of ?sess () in
  Hashtbl.clear sess.module_cache;
  Hashtbl.clear sess.type_index;
  Hashtbl.clear sess.trait_index;
  Hashtbl.clear sess.resource_cleanup_index;
  sess.load_errors <- [];
  sess.prelude_modules_loaded <- false

(** Full reset including parse cache. Use when reusing a session would be
    incorrect, or when a caller explicitly wants to release parsed modules. *)
let full_reset ?sess () =
  let sess = sess_of ?sess () in
  reset ~sess ();
  Hashtbl.clear sess.parse_cache

let rec find_blorp_config_from dir depth =
  if depth > 10 then None
  else
    let config = Filename.concat dir "blorp.toml" in
    if file_exists config && not (is_directory config) then Some config
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else find_blorp_config_from parent (depth + 1)

let rec find_pkg_root_from dir depth =
  if depth > 10 then None
  else
    let candidate = Filename.concat dir "pkg" in
    if is_directory candidate then Some candidate
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else find_pkg_root_from parent (depth + 1)

let parse_toml_string_value value =
  let value = String.trim value in
  let len = String.length value in
  if len < 2 then None
  else
    let quote = value.[0] in
    if quote <> '"' && quote <> '\'' then None
    else
      let rec find_end i escaped =
        if i >= len then None
        else
          let c = value.[i] in
          if quote = '"' && c = '\\' && not escaped then find_end (i + 1) true
          else if c = quote && not escaped then Some i
          else find_end (i + 1) false
      in
      match find_end 1 false with
      | Some i -> Some (String.sub value 1 (i - 1))
      | None -> None

let parse_blorp_config_std_path contents =
  let current_section = ref None in
  let result = ref None in
  let parse_line raw =
    let line = String.trim raw in
    if line = "" || line.[0] = '#' then ()
    else if line.[0] = '[' then
      match String.index_opt line ']' with
      | Some close when close > 1 ->
          current_section := Some (String.trim (String.sub line 1 (close - 1)))
      | _ -> ()
    else
      match String.index_opt line '=' with
      | None -> ()
      | Some eq -> (
          let key = String.trim (String.sub line 0 eq) in
          let value = String.sub line (eq + 1) (String.length line - eq - 1) in
          let is_std_path =
            key = "std.path" || (key = "path" && !current_section = Some "std")
          in
          if is_std_path then
            match parse_toml_string_value value with
            | Some path when String.trim path <> "" -> result := Some path
            | _ -> ())
  in
  List.iter parse_line (String.split_on_char '\n' contents);
  !result

let blorp_config_std_path_from base_dir =
  match find_blorp_config_from base_dir 0 with
  | None -> None
  | Some config -> (
      match parse_blorp_config_std_path (read_file config) with
      | None -> None
      | Some dir ->
          if Filename.is_relative dir then
            Some (Filename.concat (Filename.dirname config) dir)
          else Some dir)

let config_error ?help ~config_path ~line message =
  {
    Ast.message;
    loc = Ast.point_loc_in ~file:config_path ~line ~column:1;
    phase = Ast.ModuleLoad;
    kind = Ast.OtherError;
    notes = [];
    help;
  }

let package_manifest_error ~alias err =
  let location =
    match (err.Package_manifest.path, err.line) with
    | Some path, Some line -> Printf.sprintf "%s:%d" path line
    | Some path, None -> path
    | None, Some line -> Printf.sprintf "line %d" line
    | None, None -> "package manifest"
  in
  Printf.sprintf "package alias %S is invalid: %s: %s" alias location
    err.message

let source_package_missing_exports source_dir manifest =
  List.filter
    (fun module_name ->
      not (file_exists (source_package_module_file source_dir module_name)))
    manifest.Package_manifest.exports

let collect_package_source_files source_dir =
  let rec walk path =
    if is_directory path then
      Sys.readdir path |> Array.to_list |> List.sort String.compare
      |> List.concat_map (fun name -> walk (Filename.concat path name))
    else if Filename.check_suffix path ".brp" then [ path ]
    else []
  in
  walk source_dir

let package_hash_pin_error (entry : Package_config.package_path) package_root
    source_dir =
  let open Package_config in
  match entry.package_hash_pin with
  | None -> None
  | Some pin -> (
      match
        Package_hash.hash_checked_package ~root:package_root
          ~source_files:(collect_package_source_files source_dir)
      with
      | Error errors -> Some (Package_hash.render_errors errors)
      | Ok actual ->
          if Package_hash.hash_matches_pin ~pin actual then None
          else
            Some
              (Printf.sprintf
                 "package alias %S hash mismatch: expected %s, found %s"
                 entry.package_alias pin actual))

type package_alias_root_error =
  | PackageAliasRootError of string
  | PackageAliasCacheUnavailable of { pin : string; detail : string }

let package_alias_root_error (entry : Package_config.package_path) =
  let open Package_config in
  match entry.package_path with
  | Some path -> Ok path
  | None -> (
      match entry.package_hash_pin with
      | None ->
          Error
            (PackageAliasRootError
               (Printf.sprintf
                  "package alias %S must define path or hash in this \
                   source-package preview"
                  entry.package_alias))
      | Some pin -> (
          match Package_cache_layout.find_cached_path pin with
          | Ok (path, _) -> Ok path
          | Error errors ->
              Error
                (PackageAliasCacheUnavailable
                   { pin; detail = Package_cache_layout.render_errors errors }))
      )

let package_cache_fetch_help (entry : Package_config.package_path) =
  if entry.Package_config.package_from = [] then
    Printf.sprintf
      "Add from = [...] for package %S and run `blorp package fetch %s`, or \
       configure a local path."
      entry.Package_config.package_alias entry.Package_config.package_alias
  else
    Printf.sprintf
      "Run `blorp package fetch %s` from the project directory before \
       compiling."
      entry.Package_config.package_alias

let configure_source_package_alias ~(sess : Session.t) ~config_path
    (entry : Package_config.package_path) =
  let open Package_config in
  let add_error ?help line message =
    sess.load_errors <-
      config_error ?help ~config_path ~line message :: sess.load_errors
  in
  match package_alias_root_error entry with
  | Error (PackageAliasRootError message) ->
      add_error entry.package_line message
  | Error (PackageAliasCacheUnavailable { pin; detail }) ->
      add_error entry.package_line
        ~help:(package_cache_fetch_help entry)
        (Printf.sprintf
           "package alias %S cannot use hash %s from the local package cache: \
            %s"
           entry.package_alias pin detail)
  | Ok package_root -> (
      let manifest_path =
        Filename.concat package_root Package_manifest.manifest_filename
      in
      match Package_manifest.read manifest_path with
      | Error errors ->
          List.iter
            (fun err ->
              add_error entry.package_line
                (package_manifest_error ~alias:entry.package_alias err))
            errors
      | Ok manifest -> (
          if manifest.std_compat <> Package_manifest.current_std_compat then
            add_error entry.package_line
              (Printf.sprintf
                 "package alias %S requires std compat %S, but this compiler \
                  supports %S"
                 entry.package_alias manifest.std_compat
                 Package_manifest.current_std_compat)
          else
            let source_dir = Filename.concat package_root "src" in
            if not (is_directory source_dir) then
              add_error entry.package_line
                (Printf.sprintf
                   "package alias %S must point to a source package with a \
                    src/ directory"
                   entry.package_alias)
            else
              match source_package_missing_exports source_dir manifest with
              | missing :: _ ->
                  add_error entry.package_line
                    (Printf.sprintf
                       "package alias %S exports module %S, but %s does not \
                        exist"
                       entry.package_alias missing
                       (source_package_module_file source_dir missing))
              | [] -> (
                  match
                    package_hash_pin_error entry package_root source_dir
                  with
                  | Some message -> add_error entry.package_line message
                  | None ->
                      add_source_package ~sess
                        {
                          source_package_alias = entry.package_alias;
                          source_package_name = manifest.name;
                          source_package_root = canonical_dir package_root;
                          source_package_source_dir = canonical_dir source_dir;
                          source_package_exports = manifest.exports;
                        })))

(** Initialize module paths for a given base directory.
    Filesystem std is used only when configured explicitly through
    [--std-dir], [BLORP_STD], or [blorp.toml]. Otherwise std imports use
    the embedded standard library. *)
let init_module_paths ?sess base_dir =
  let sess = sess_of ?sess () in
  let cwd = Sys.getcwd () in
  let abs_base_dir =
    if Filename.is_relative base_dir then Filename.concat cwd base_dir
    else base_dir
  in
  (* Precedence: --std-dir, BLORP_STD, blorp.toml, then embedded std. *)
  (if not sess.std_override_active then
     match Sys.getenv_opt "BLORP_STD" with
     | Some dir when dir <> "" -> set_std_override ~sess dir
     | _ -> (
         match blorp_config_std_path_from abs_base_dir with
         | Some dir -> set_std_override ~sess dir
         | None -> ()));
  (match Package_config.package_paths_from abs_base_dir with
  | None -> ()
  | Some (config_path, parsed) ->
      List.iter
        (fun (line, message) ->
          sess.load_errors <-
            config_error ~config_path ~line message :: sess.load_errors)
        parsed.Package_config.package_errors;
      List.iter
        (configure_source_package_alias ~sess ~config_path)
        parsed.Package_config.package_paths);
  let cwd_pkg = Filename.concat cwd "pkg" in
  if is_directory cwd_pkg then add_package_root ~sess cwd_pkg;
  Option.iter (add_package_root ~sess) (find_pkg_root_from abs_base_dir 0);
  add_search_path ~sess (Sys.getcwd ())

(** Parse source text into an AST program.
    Runs the Blorp parser bridge and returns a structured error on failure. *)
let parse_source_at_phase ?sess ?filename ?(bridge_read_file = false) ~phase
    source =
  let path = Option.value filename ~default:"<source>" in
  let module_name = bridge_module_name_for_path ?sess path in
  match
    parse_source_with_blorp_bridge ~phase ~path ~module_name
      ~bridge_read_file:(bridge_read_file && not (String.equal path "<source>"))
      source
  with
  | Ok program -> Ok program
  | Error (BridgeParseCompilerErrors (err :: _)) -> Error err
  | Error (BridgeParseCompilerErrors []) ->
      Error
        (parse_error_for_message ?filename
           "Blorp parser returned no program and no diagnostics")
  | Error (BridgeParseMessage message) ->
      Error (parse_error_for_message ?filename message)

let parse_source ?sess ?filename ?(bridge_read_file = false) source =
  parse_source_at_phase ?sess ?filename ~bridge_read_file
    ~phase:Compiler_blorp_bridge.RawParsedProgram source

let parse_typecheck_source ?sess ?filename ?(bridge_read_file = false) source =
  parse_source_at_phase ?sess ?filename ~bridge_read_file
    ~phase:Compiler_blorp_bridge.TypecheckSourceProgram source
