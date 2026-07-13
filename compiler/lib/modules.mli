(** Module System for blorp

    Handles module loading, path resolution, and caching.

    {1 Session threading (Phase 2.1)}

    All stateful functions take an optional [?sess] argument. When
    omitted, they use the ambient current session ([Session.current ()]).
    Frontend entry points scope their work with [Session.with_current]
    so nested calls see the right session.
*)

val contains : string -> string -> bool
(** Substring search: check if [s] contains [sub] *)

type loaded_module = Session.loaded_module = {
  name : string;
  path : string;
  origin : Session.module_origin;
  decls : Ast.program;
  exports : (string * Ast.decl) list;
  surface : Module_surface.t option;
  mutable typed_decls : Typed_ast.program option;
  mutable typed_import_bindings : Session.import_binding list option;
}
(** A loaded module — single source of truth for parsed + typed AST.
    Alias for [Session.loaded_module] so existing qualified uses
    ([Modules.loaded_module]) keep working. *)

val is_package_loaded_module : loaded_module -> bool
(** True iff this loaded module came from an explicit package import. *)

val is_path_under_dir : dir:string -> string -> bool
(** True iff [path] is [dir] or a descendant of [dir], using canonical
    filesystem paths and directory boundaries rather than string prefixes. *)

type source_package = Session.source_package = {
  source_package_alias : string;
  source_package_name : string;
  source_package_root : string;
  source_package_source_dir : string;
  source_package_exports : string list;
}
(** A root-project source package alias. These are configured from
    [blorp.toml] or directly by package tooling. *)

type preloaded_parsed_source = {
  preload_module_name : string;
  preload_path : string;
  preload_origin : Session.module_origin;
  preload_source : string;
  preload_decls : Ast.program;
  preload_surface : Module_surface.t option;
}
(** Parsed source supplied by the Blorp CLI frontend graph for the current
    compiler invocation. Graph loading resolves imports from explicit graph
    edges; matching entries can reuse this finalized source AST and module
    surface without rereading, reparsing, or rediscovering syntactic module
    facts from declarations. *)

type parsed_source_artifact = {
  source_artifact_program : Ast.program;
  source_artifact_surface : Module_surface.t option;
}
(** Parsed source plus the syntactic module surface produced by the Blorp parser
    bridge. Prefer this over plain AST parsing when the caller will immediately
    load imports, because the surface is the authoritative source of syntactic
    import/export/private-name facts. *)

type preloaded_import_edge = {
  preload_import_from_path : string;
  preload_import_from_module : string;
  preload_import_path : string;
  preload_import_resolved_path : string option;
  preload_import_resolved_module : string option;
  preload_import_resolved_origin : Session.module_origin option;
}
(** Import edge supplied by the Blorp-owned frontend graph. Resolved edges must
    point at a source in [preloaded_module_graph.preload_graph_sources].
    Unresolved edges are accepted only for embedded-std imports while OCaml
    still owns embedded std storage. *)

type preloaded_module_graph_context = {
  preload_graph_std_dir : string option;
  preload_graph_source_packages : source_package list;
  preload_graph_package_roots : string list;
}
(** Module context discovered by the Blorp CLI/source graph. This is applied
    to the fresh pipeline session before graph loading so package/std policy
    does not depend on rediscovering project files in the OCaml shell. *)

type preloaded_module_graph = {
  preload_graph_context : preloaded_module_graph_context;
  preload_graph_sources : preloaded_parsed_source list;
  preload_graph_imports : preloaded_import_edge list;
}
(** Closed frontend graph supplied by the Blorp CLI. The pipeline consumes this
    graph directly instead of asking OCaml to resolve and parse the same import
    tree again. *)

val add_source_package : ?sess:Session.t -> source_package -> unit
(** Add or replace a source package alias in the active session. *)

val module_origin_for_source_file :
  ?sess:Session.t -> string -> Session.module_origin
(** Classify a source file for compiler policy when only a path is available. *)

val module_name_for_source_file : ?sess:Session.t -> string -> string option
(** Return the canonical std or source-package module name for [path] when the
    active session knows one. User files without canonical package/std identity
    return [None]. *)

val std_module_name_for_source_file : ?sess:Session.t -> string -> string option
(** Return the canonical std module name for a filesystem std source path,
    e.g. [/repo/std/result.brp] -> [Some "std/result"]. *)

val add_search_path : ?sess:Session.t -> string -> unit
(** Add a directory to the module search paths. *)

val add_package_root : ?sess:Session.t -> string -> unit
(** Add a local package root. [pkg/foo/bar] resolves to
    [<root>/foo/bar.brp] and receives package origin [foo]. Bare imports never
    consult package roots. *)

val package_roots : ?sess:Session.t -> unit -> string list
(** Local package roots configured for this session, in lookup order. *)

val set_std_override : ?sess:Session.t -> string -> unit
(** Override the embedded std library with a filesystem directory.
    Used by [--std-dir] CLI flag. Takes priority over [BLORP_STD]
    and [blorp.toml]. *)

val load_module : ?sess:Session.t -> string -> string -> loaded_module option
(** Load a module by name, resolving from base directory.
    Returns [None] if the module cannot be found or parsed. *)

val load_imports :
  ?sess:Session.t ->
  ?surface:Module_surface.t ->
  Ast.program ->
  string ->
  loaded_module list
(** Load all imports for a parsed module.

    When [surface] is present, its Blorp-produced import list is authoritative;
    [decls] is only a legacy fallback for non-surface callers.
    Returns the list of successfully loaded modules. *)

val load_preloaded_module_graph :
  ?sess:Session.t -> target_path:string -> preloaded_module_graph -> unit
(** Load the module dependency closure reachable from [target_path] using only
    graph-provided sources and import edges. Any missing non-embedded-std edge
    is recorded as a module-load diagnostic instead of falling back to
    filesystem discovery. *)

val get_all_modules : ?sess:Session.t -> unit -> loaded_module list
(** Get all loaded modules in dependency order. *)

val prune_parse_cache_to_loaded_modules : ?sess:Session.t -> unit -> unit
(** Remove non-stdlib parse-cache entries that are not part of the currently
    loaded module graph. LSP uses this after rebuilding a document graph so
    import edits do not leave old user modules resident. *)

val find_cached : ?sess:Session.t -> string -> loaded_module option
(** Look up a module in the cache by name. *)

val get_typed_decls : ?sess:Session.t -> string -> Typed_ast.program option
(** Look up typed AST for a module (stored in the module's [typed_decls] field). *)

val set_typed_decls : ?sess:Session.t -> string -> Typed_ast.program -> unit
(** Store typed AST for a module (sets the module's [typed_decls] field). *)

val set_typed_import_bindings :
  ?sess:Session.t -> string -> Session.import_binding list -> unit
(** Store resolved import bindings for a typed module. *)

val get_load_errors : ?sess:Session.t -> unit -> Ast.compiler_error list
(** Get accumulated module loading errors (e.g., module not found,
    parse failures in imported modules). Cleared on [reset]. Returned
    newest-first — the pipeline reverses before surfacing. *)

val reset : ?sess:Session.t -> unit -> unit
(** Reset the active module graph between compilations.
    The parse cache is preserved to avoid re-parsing std library modules.

    Prefer [Session.create ()] for full isolation. *)

val full_reset : ?sess:Session.t -> unit -> unit
(** Full reset including parse cache. Use when reusing a session would be
    incorrect, or when a caller explicitly wants to release parsed modules. *)

val read_file : string -> string
(** Read a file's contents. *)

val extract_directory : string -> string
(** Extract the directory portion of a path. *)

val init_module_paths : ?sess:Session.t -> string -> unit
(** Initialize module search paths for a given base directory.
    Sets up CWD, explicit std overrides, and local [pkg/] package roots.
    Standard library override precedence is [--std-dir], [BLORP_STD],
    [blorp.toml], then embedded std; filesystem [std/] directories are not
    guessed. *)

val std_source_dir : ?sess:Session.t -> unit -> string option
(** Filesystem std source directory established by {!init_module_paths} or
    {!set_std_override}. Source-inspection tools should use this instead of
    deriving [std/] paths from their current working directory. *)

val parse_raw_source :
  ?sess:Session.t ->
  ?filename:string ->
  ?bridge_read_file:bool ->
  string ->
  (Ast.program, Ast.compiler_error) result
(** Parse source text into a raw AST program through the Blorp parser bridge,
    preserving parser-level forms for parse-only tooling. Raw parse never
    finalizes interpolation, hoists nested functions, or lowers subscript reads;
    callers that need typecheck-ready source must use {!parse_typecheck_source}.
    Filesystem-backed callers can pass [~bridge_read_file:true] to let the
    Blorp bridge executable read the source file before parsing. Returns a
    structured error on parse failure. *)

val parse_raw_source_artifact :
  ?sess:Session.t ->
  ?filename:string ->
  ?bridge_read_file:bool ->
  string ->
  (parsed_source_artifact, Ast.compiler_error) result
(** Like {!parse_raw_source}, but preserves the parser bridge module surface
    for raw tooling callers that need import information. *)

val parse_typecheck_source :
  ?sess:Session.t ->
  ?filename:string ->
  ?bridge_read_file:bool ->
  string ->
  (Ast.program, Ast.compiler_error) result
(** Parse source text into the source AST shape expected by typechecking.
    This requests the Blorp bridge's [typecheck_source] phase so parser-owned
    rewrites such as interpolation finalization, nested-function hoisting, and
    subscript-read lowering happen before semantic analysis. *)

val parse_typecheck_source_artifact :
  ?sess:Session.t ->
  ?filename:string ->
  ?bridge_read_file:bool ->
  string ->
  (parsed_source_artifact, Ast.compiler_error) result
(** Like {!parse_typecheck_source}, but preserves the parser bridge module
    surface for module loading. *)

val semantic_exports_from_program : Ast.program -> (string * Ast.decl) list
(** Convert a semantic typed export program into module export pairs.

    Syntactic exports for parsed modules come from the Blorp module surface on
    production parse/cache paths; AST scanning remains an internal fallback for
    legacy non-surface callers. *)

val private_names_for_import_diagnostics :
  loaded_module -> (string * Ast.decl) list
(** Collect private names for selective-import diagnostics. Surface-backed
    modules use the parser bridge surface. Legacy non-surface callers fall back
    to an internal AST scanner. *)

val exported_func_is_debug_only : string -> string -> bool
(** True when the cached module exports [func_name] as a function explicitly
    declared [@debug_only]. Typed exports are preferred when available. *)

val suggest_export : loaded_module -> string -> string option
(** Suggest a similar export name for typo correction *)

val prelude_module_names : string list
(** Canonical names of prelude modules whose exports are available without import. *)
