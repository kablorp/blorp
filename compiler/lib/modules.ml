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
  mutable typed_decls : Typed_ast.program option;
  mutable typed_import_bindings : Session.import_binding list option;
}
(** Module representation — imported from [Session] where it lives
    alongside the per-session module cache. Re-exported here so existing
    callers keep seeing [Modules.loaded_module]. *)

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

let is_std_loaded_module (m : loaded_module) =
  Session.module_origin_is_std m.origin

let is_package_loaded_module (m : loaded_module) =
  Session.module_origin_is_package m.origin

let is_std_source_file ?sess path =
  let s = sess_of ?sess () in
  if has_prefix "<embedded:std/" path then true
  else
    match s.std_source_dir with
    | Some dir -> is_path_under_dir ~dir path
    | None -> false

let module_origin_for_source_file ?sess path =
  if is_std_source_file ?sess path then Session.Stdlib_module
  else Session.User_module

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

let is_directory path =
  try Sys.file_exists path && Sys.is_directory path with _ -> false

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

let resolve_module_file ?sess base_dir module_name =
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
  else if has_prefix "pkg/" module_name then
    match package_ref_of_module_name module_name with
    | None -> None
    | Some pkg ->
        List.find_map
          (fun root ->
            let candidate = with_ext (Filename.concat root pkg.package_path) in
            if file_exists candidate then
              Some
                {
                  resolved_path = candidate;
                  resolved_origin = Session.package_origin pkg.package_id;
                }
            else None)
          s.package_roots
  else if has_prefix "./" module_name then
    let rest = strip_prefix "./" module_name in
    let candidate = with_ext (Filename.concat base_dir rest) in
    if file_exists candidate then
      Some { resolved_path = candidate; resolved_origin = Session.User_module }
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
      Some { resolved_path = candidate; resolved_origin = Session.User_module }
    else None
  (* Default: try as-is relative to base_dir *)
    else
    let candidate = with_ext (Filename.concat base_dir module_name) in
    if file_exists candidate then
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

(** Explicit migration hints for renamed std exports. These run before typo
    correction so API renames do not produce misleading near-name suggestions
    such as [is_upper] for the old string case-conversion functions. *)
let renamed_std_export_hint (m : loaded_module) (name : string) : string option
    =
  if (not (is_std_loaded_module m)) || Filename.basename m.name <> "string" then
    None
  else
    match name with
    | "to_upper" ->
        Some "'to_upper' was renamed to 'upper'; write `import: string: upper`"
    | "to_lower" ->
        Some "'to_lower' was renamed to 'lower'; write `import: string: lower`"
    | _ -> None

(** Suggest a similar export name for typo correction.
    Uses simple Levenshtein-like matching on module exports. *)
let suggest_export (m : loaded_module) (name : string) : string option =
  match renamed_std_export_hint m name with
  | Some hint -> Some hint
  | None -> (
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
      | None -> None)

let std_module_available ~(sess : Session.t) ~base_dir module_name =
  has_prefix "std/" module_name
  && ((not sess.std_override_active)
      && Option.is_some (Embedded_std.find module_name)
     ||
     match resolve_module_path ~sess base_dir module_name with
     | Some path -> is_std_source_file ~sess path
     | None -> false)

(** Load a module by name
    @param module_name Module name like "std/List"
    @param base_dir Directory of the importing file
    @return Some(module) if successful, None otherwise
*)
let rec load_module ?sess module_name base_dir =
  let sess = sess_of ?sess () in
  (* Bare imports (no std/, ./, ../ prefix) resolve to std/ canonical name *)
  let is_bare =
    (not (has_prefix "std/" module_name))
    && (not (has_prefix "pkg/" module_name))
    && (not (has_prefix "./" module_name))
    && not (has_prefix "../" module_name)
  in
  let relative_path_alias =
    if has_prefix "./" module_name || has_prefix "../" module_name then
      resolve_module_path ~sess base_dir module_name
    else None
  in
  let load_bare_or_direct () =
    if is_bare then
      (* Bare names prefer std modules only when a std module is known to
         exist. The availability check is side-effect free: a failed std
         probe must not leave diagnostics behind when a local module of the
         same bare name exists. *)
      let std_name = "std/" ^ module_name in
      match Hashtbl.find_opt sess.module_cache std_name with
      | Some m ->
          Hashtbl.replace sess.module_cache module_name m;
          Some m
      | None ->
          if std_module_available ~sess ~base_dir std_name then
            match load_module_inner ~sess std_name base_dir with
            | Some m ->
                Hashtbl.replace sess.module_cache module_name m;
                Some m
            | None -> None
          else load_module_inner ~sess module_name base_dir
    else load_module_inner ~sess module_name base_dir
  in
  match Hashtbl.find_opt sess.module_cache module_name with
  | Some m -> Some m
  | None -> (
      match Option.bind relative_path_alias (find_cached_by_path sess) with
      | Some m ->
          Hashtbl.replace sess.module_cache module_name m;
          Some m
      | None -> load_bare_or_direct ())

(** Stamp the filename onto a lexbuf so positions recorded by the parser
    (and thus [Ast.loc.loc_file]) carry the source file they came from. *)
and set_lexbuf_filename (lexbuf : Lexing.lexbuf) (path : string) =
  lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = path };
  lexbuf.lex_start_p <- { lexbuf.lex_start_p with pos_fname = path }

(** Parse source text for a module, caching the result.
    Shared by embedded and filesystem module loading. *)
and parse_module_source ~(sess : Session.t) ~module_name ~path ~origin source =
  Lexer.reset_state ();
  let lexbuf = Lexing.from_string source in
  set_lexbuf_filename lexbuf path;
  let record_err ~line ~col msg =
    (* Collect into the session's [load_errors] list so the pipeline
       can surface parse failures through the normal diagnostic
       channel (see [Pipeline.module_load_errors]). The parser must
       not print directly to stderr — that bypasses formatting and
       breaks structured error consumers. The message carries the
       module path and real source position so downstream formatters
       can render the same source-snippet style they use for other
       errors. *)
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
    sess.Session.load_errors <- err :: sess.load_errors;
    None
  in
  try
    let decls = Parser.program Lexer.next_token lexbuf in
    let decls = Interp_parser.transform_program decls in
    (* Keep imported modules on the same parse-postprocess path as the
       main source. After this point no [EFuncDecl] should survive into
       typecheck/Core lowering. Subscript desugaring still belongs to the
       typecheck pipeline so formatting can preserve the user's [x[i]]
       syntax. *)
    match
      try Ok (Nested_hoist.hoist_program decls)
      with Nested_hoist.Capture_error err -> Error err
    with
    | Ok decls ->
        let exports = collect_exports decls in
        Hashtbl.replace sess.parse_cache module_name
          (path, origin, decls, exports);
        Some (path, origin, decls, exports)
    | Error err ->
        sess.load_errors <- err :: sess.load_errors;
        None
  with
  | Lexer.LexError (msg, line, col) -> record_err ~line ~col msg
  | Ast.Parse_error_at (loc, msg) ->
      record_err ~line:loc.line ~col:loc.column msg
  | Parser.Error ->
      let line, col = Lexer.current_pos () in
      let token_info =
        match Lexer.last_token () with
        | Some tok ->
            Printf.sprintf "Parse error in module '%s': unexpected %s"
              module_name
              (Lexer.token_to_string tok)
        | None -> Printf.sprintf "Parse error in module '%s'" module_name
      in
      record_err ~line ~col token_info
  | Interp_parser.InterpParseError (msg, loc) ->
      record_err ~line:loc.line ~col:loc.column msg

and load_module_inner ~(sess : Session.t) module_name base_dir =
  match Hashtbl.find_opt sess.Session.module_cache module_name with
  | Some m -> Some m
  | None -> (
      (* Try parse cache (avoids re-parsing std modules between tests) *)
      let parsed =
        match Hashtbl.find_opt sess.parse_cache module_name with
        | Some _ as cached -> cached
        | None -> (
            let from_embedded =
              if has_prefix "std/" module_name && not sess.std_override_active
              then
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
                            \  = help: Check --std-dir, BLORP_STD, or \
                             blorp.toml; remove the override to use the \
                             embedded standard library"
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
                      else begin
                        let suggestion =
                          let lower = String.lowercase_ascii module_name in
                          if lower <> module_name then
                            match resolve_module_path ~sess base_dir lower with
                            | Some _ ->
                                Printf.sprintf " (did you mean '%s'?)" lower
                            | None -> ""
                          else ""
                        in
                        Printf.sprintf
                          "Could not find module '%s'%s\n  Search paths: %s"
                          module_name suggestion
                          (String.concat ", " sess.search_paths)
                      end
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
            )
      in
      match parsed with
      | None -> None
      | Some (path, origin, decls, exports) ->
          (* Create module and add to active cache *)
          let m =
            {
              name = module_name;
              path;
              origin;
              decls;
              exports;
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
          let module_dir = extract_directory path in
          let _ = load_imports ~sess decls module_dir in
          Some m)

(** Load all imports from a list of declarations.
    Ensures prelude modules (option, result) are loaded on first call,
    since their type definitions are needed by codegen for any program
    that uses these prelude types without explicit imports. *)
and load_imports ?sess decls base_dir =
  let sess = sess_of ?sess () in
  if not sess.prelude_modules_loaded then begin
    sess.prelude_modules_loaded <- true;
    List.iter
      (fun m -> ignore (load_module ~sess m base_dir))
      eager_typecheck_support_modules
  end;
  List.filter_map
    (fun decl ->
      match decl.decl_desc with
      | DImport imp -> load_module ~sess imp.import_module base_dir
      | _ -> None)
    decls

(** Get module dependencies (names of modules it imports) *)
let get_dependencies m =
  List.filter_map
    (fun decl ->
      match decl.decl_desc with
      | DImport imp -> Some imp.import_module
      | _ -> None)
    m.decls

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
  sess.load_errors <- [];
  sess.prelude_modules_loaded <- false

(** Full reset including parse cache.
    Use in the LSP server where source files may have changed since last parse. *)
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
  let cwd_pkg = Filename.concat cwd "pkg" in
  if is_directory cwd_pkg then add_package_root ~sess cwd_pkg;
  Option.iter (add_package_root ~sess) (find_pkg_root_from abs_base_dir 0);
  add_search_path ~sess (Sys.getcwd ())

(** Parse source text into an AST program.
    Resets lexer state, runs the parser, and applies string interpolation
    transform. Catches all known parse exceptions and returns a structured
    error on failure. *)
let parse_source ?sess ?filename ?(hoist_nested = true) source =
  let _ = sess_of ?sess () in
  (* Acknowledge ambient; lexer state still module-level in Phase 2.1a *)
  Lexer.reset_state ();
  let lexbuf = Lexing.from_string source in
  Option.iter (set_lexbuf_filename lexbuf) filename;
  try
    let program = Parser.program Lexer.next_token lexbuf in
    let program = Interp_parser.transform_program program in
    (* Compiler callers hoist nested [func] declarations out of function
       bodies into top-level [DFunc]s. Formatters and source-inspection tools
       can opt out so they preserve parser-level [EFuncDecl] nodes. See
       [nested_hoist.ml] for the compiler lowering behavior. *)
    let hoisted =
      if hoist_nested then
        try Ok (Nested_hoist.hoist_program program)
        with Nested_hoist.Capture_error err -> Error err
      else Ok program
    in
    match hoisted with
    | Ok program ->
        (* See note in [load_module_once] — subscript desugaring is
            applied by the typecheck pipeline, not here. *)
        Ok program
    | Error err -> Error err
  with
  | Parser.Error ->
      let line, col = Lexer.current_pos () in
      let msg =
        match Lexer.last_token () with
        | Some tok ->
            Printf.sprintf "Parse error: unexpected %s"
              (Lexer.token_to_string tok)
        | None -> "Parse error"
      in
      (* Scan the source line for common keywords/patterns from other languages *)
      let help =
        let lines = String.split_on_char '\n' source in
        if line >= 1 && line <= List.length lines then
          let source_line = String.trim (List.nth lines (line - 1)) in
          let first_word =
            match String.index_opt source_line ' ' with
            | Some i -> String.sub source_line 0 i
            | None -> source_line
          in
          (* First: check first-word keywords from other languages *)
          match first_word with
          | "def" ->
              Some
                "blorp uses 'func' instead of 'def'. Write 'func name(params) \
                 -> ReturnType:'"
          | "fn" ->
              Some
                "blorp uses 'func' instead of 'fn'. Write 'func name(params) \
                 -> ReturnType:'"
          | "fun" ->
              Some
                "blorp uses 'func' instead of 'fun'. Write 'func name(params) \
                 -> ReturnType:'"
          | "class" ->
              Some
                "blorp uses 'record' for data types and 'union' for algebraic \
                 types, not 'class'"
          | "elif" -> Some "blorp uses 'else if' instead of 'elif'"
          | "elsif" -> Some "blorp uses 'else if' instead of 'elsif'"
          | "switch" ->
              Some "blorp uses 'match' instead of 'switch'. Write 'match expr:'"
          | _ -> (
              if
                (* Second: check for token patterns in the source line *)
                contains source_line "=>"
              then
                Some
                  "blorp uses 'func(x): body' for lambdas, not '=>' arrow \
                   syntax"
              else if contains source_line ":=" then
                Some "blorp uses '=' for assignment, not ':='"
              else if
                (* Third: check for lambda-like syntax without func keyword *)
                contains source_line "-> Int:"
                || contains source_line "-> String:"
                || contains source_line "-> Float:"
                || contains source_line "-> Bool:"
                || contains source_line "-> Void:"
              then
                match Lexer.last_token () with
                | Some Parser.COLON ->
                    Some
                      "lambdas require the 'func' keyword: func(x: Int) -> \
                       Int: body"
                | _ -> None
              else
                (* Fourth: check the unexpected token itself *)
                match Lexer.last_token () with
                | Some Parser.LBRACE ->
                    Some
                      "blorp uses colon + indentation for blocks, not curly \
                       braces"
                | Some Parser.NEWLINE ->
                    (* Check if previous line looks like a func signature missing ':' *)
                    let prev_line =
                      if line >= 2 && line - 1 <= List.length lines then
                        String.trim (List.nth lines (line - 2))
                      else ""
                    in
                    if contains prev_line "->" && contains prev_line "func "
                    then Some "Expected ':' after function signature"
                    else None
                | _ -> None)
        else None
      in
      let mk_loc line col =
        match filename with
        | Some f -> Ast.point_loc_in ~file:f ~line ~column:col
        | None -> Ast.point_loc ~line ~column:col
      in
      Error
        {
          Ast.message = msg;
          loc = mk_loc line col;
          phase = Parse;
          kind = OtherError;
          notes = [];
          help;
        }
  | Lexer.LexError (msg, line, col) ->
      let loc =
        match filename with
        | Some f -> Ast.point_loc_in ~file:f ~line ~column:col
        | None -> Ast.point_loc ~line ~column:col
      in
      Error
        {
          Ast.message = msg;
          loc;
          phase = Parse;
          kind = OtherError;
          notes = [];
          help = None;
        }
  | Interp_parser.InterpParseError (msg, loc) ->
      let loc =
        match (filename, loc.loc_file) with
        | Some f, None -> { loc with loc_file = Some f }
        | _ -> loc
      in
      Error
        {
          Ast.message = msg;
          loc;
          phase = Parse;
          kind = OtherError;
          notes = [];
          help = None;
        }
  | Ast.Parse_error_at (loc, msg) ->
      let loc =
        match (filename, loc.loc_file) with
        | Some f, None -> { loc with loc_file = Some f }
        | _ -> loc
      in
      Error
        {
          Ast.message = msg;
          loc;
          phase = Parse;
          kind = OtherError;
          notes = [];
          help = None;
        }
  | Failure msg ->
      let line, col = Lexer.current_pos () in
      let loc =
        match filename with
        | Some f -> Ast.point_loc_in ~file:f ~line ~column:col
        | None -> Ast.point_loc ~line ~column:col
      in
      Error
        {
          Ast.message = msg;
          loc;
          phase = Parse;
          kind = OtherError;
          notes = [];
          help = None;
        }
