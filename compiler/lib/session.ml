(** Compilation session — a single-compilation state container.

    A [Session.t] holds the per-compilation state that used to live as
    module-level mutable refs in [Types] (meta-env) and [Modules]
    (module cache, parse cache, search paths, load errors, std
    override, prelude-loaded flag). Lexer state is a known exception
    and stays module-level for now — see the comment above the record
    definition.

    Replacing those refs with a session unlocks:

    - Multi-buffer LSP (each open document gets its own session)
    - Parallel test compilation (no cross-test state leakage)
    - Incremental module-level rebuilds
    - Removes the "every reset bug lives here" class of flakes

    {1 State lifetimes}

    Fields have two distinct lifetimes:

    - {b compilation}: lives for the whole compile. Cleared only by
      creating a new session ([Session.create]).
    - {b inference}: lives for a single function body. Cleared between
      bodies by [Session.reset_meta]. (HM semantics — meta variables
      are per-body.)

    A single long-running session (e.g. the REPL's) reuses one
    session for many parse-and-typecheck cycles; it invokes
    [reset_meta] at the appropriate boundaries. A one-shot compile
    creates a session at the start and drops it at the end.

    {1 Concurrency}

    Two sessions are fully independent. Multiple sessions coexist in
    the same OCaml process without any cross-contamination. Within a
    single session, all mutation is sequential; the frontend is not
    internally multi-threaded.

    {1 Data-type placement}

    [loaded_module] is defined here rather than in [Modules] because
    [Session] embeds it and OCaml doesn't allow forward references
    across module boundaries. [Modules] re-exports the type under its
    original name. *)

open Ast

(* ============================================================================
   Lexer state — DEFERRED
   ============================================================================

   Blorp's lexer still owns a module-level mutable state, reset by
   every parse entry via [Lexer.reset_state ()]. The ownership model
   is "one parse at a time per process" which holds today (CLI,
   REPL, LSP, test runner all run parses sequentially within a
   process).

   True session-owned lexer state requires parameterizing ocamllex
   rules ([rule next_token state = parse ...]) and threading state
   through [Parser.program] via a closure. Deferred until a concrete
   concurrent-parse use case emerges (e.g. OCaml 5 domain-local
   parallel compile jobs within a single process). *)

(* ============================================================================
   Module loading state (was [Modules.loaded_module])
   ============================================================================ *)

type import_binding = {
  local_name : string;
  module_path : string;
  original_name : string option;
}
(** A module loaded and parsed during compilation.

    Load-bearing invariant: [decls] is raw post-parse (pre-subscript-
    desugar); [typed_decls] is desugared + typed and validated through
    [Typed_ast]. The formatter reads [decls]; all typecheck-downstream
    consumers read [typed_decls]. *)

type package_id = Package_id of string

type module_origin =
  | Stdlib_module
  | Package_module of package_id
  | User_module

let package_id_name (Package_id name) = name

let package_origin name =
  let name = String.trim name in
  if name = "" then invalid_arg "package origin requires a non-empty package id"
  else Package_module (Package_id name)

let module_origin_is_std = function Stdlib_module -> true | _ -> false

let module_origin_is_package = function
  | Package_module _ -> true
  | Stdlib_module | User_module -> false

let module_origin_allows_builtin = function
  | Stdlib_module -> true
  | Package_module _ | User_module -> false

let module_origin_allows_foreign = function
  | Stdlib_module -> false
  | Package_module _ | User_module -> true

let module_origin_label = function
  | Stdlib_module -> "standard library"
  | User_module -> "user module"
  | Package_module id -> Printf.sprintf "package '%s'" (package_id_name id)

type loaded_module = {
  name : string;  (** Canonical name: "std/list", "./utils". *)
  path : string;  (** "/abs/path/to/file.brp" or "<embedded:std/list>". *)
  origin : module_origin;
  decls : program;
  exports : (string * decl) list;
  mutable typed_decls : Typed_ast.program option;
  mutable typed_import_bindings : import_binding list option;
}

(* ============================================================================
   Session record
   ============================================================================ *)

type t = {
  (* -- Compilation state (lives for the whole compile) -- *)
  mutable search_paths : string list;
      (** Directories to search for [import] resolution. *)
  mutable package_roots : string list;
      (** Explicit local package roots. A [pkg/foo/bar] import resolves to
      [<root>/foo/bar.brp] and receives [Package_module foo] origin. Bare
      imports never consult these roots. *)
  module_cache : (string, loaded_module) Hashtbl.t;
      (** Canonical module name → loaded module. *)
  parse_cache :
    (string, string * module_origin * program * (string * decl) list) Hashtbl.t;
      (** Module name → (path, origin, decls, exports). A pre-parsed store for
      fast reload. Session-scoped by design — sharing across sessions
      would require a separate process-level cache keyed by source
      hash; not worth it today. *)
  type_index : (string, string) Hashtbl.t;
      (** Type name → canonical name of the module that declared it.
      Populated by [register_module_types] whenever a module is loaded;
      keys both unions/enums ([DType]) and records ([DRecord]). Read
      by [Env.format_constructor_ref] (Track B) so a constructor's
      home module can be rendered in diagnostics: "Some (from
      std/option)". Builtins registered without a module source
      (Option/Result/ConcurrencyError from [env_builtins]) stay
      unregistered here and render bare — matches the trait-index
      pattern. *)
  trait_index : (string, string) Hashtbl.t;
      (** Trait name → canonical name of the module that declared it.

      Populated by [register_module_traits] whenever a module is loaded.
      [Env.get_trait] consults this on miss (step 3 of the uniform
      trait-inheritance plan): the supertrait graph is a property of
      the compilation, not of a specific file's import list, so a file
      that writes [T: Orderable] should see [Orderable: Equatable] even
      without [import: traits]. Private traits are NOT registered here
      — they stay module-scoped. See [register_module_traits]. *)
  mutable std_override_dir : string option;
  mutable std_override_active : bool;
      (** When set (via [--std-dir], [BLORP_STD], or [blorp.toml]), the
      embedded std library is bypassed and filesystem resolution is used. *)
  mutable std_source_dir : string option;
      (** Explicit filesystem [std/] directory selected by [--std-dir],
      [BLORP_STD], or [blorp.toml]. [None] means std imports use the embedded
      library; tools that need source files should not guess a filesystem std
      path. *)
  mutable load_errors : compiler_error list;
      (** Errors accumulated during module loading. Surfaced to the CLI. *)
  mutable prelude_modules_loaded : bool;
      (** True once the prelude modules (option/result/string/list/dict/set)
      have been loaded into this session. *)
  (* -- Env tables (lives for the whole compile; were formerly process-global) --

     These three hashtables used to live inside [Env.empty] as a
     module-level [let] binding, which made them process-global. Every
     [Env_builtins.with_builtins Env.empty] call shared the same
     tables, so overload/impl registrations accumulated across
     independent [Pipeline.compile] invocations — producing
     order-dependent failures (e.g. [./blorp test --doc std] failing
     only when multiple std modules' doctests ran in one process).

     Moving them to the session gives per-compile isolation while
     preserving the "impls visible across [typecheck_module] calls
     within one compile" invariant that prior attempts (Phase 2.1,
     reverted) broke by making the tables per-call fresh.

     [Env.empty ()] reads [Session.current ()] and aliases these
     hashtables into the env record, so every existing
     [env.overloads] / [env.impl_index] / [env.ufcs_methods] call
     site reads/writes the session's tables through the alias with
     no signature churn. *)
  overloads : (string, Env_types.overload_entry list) Hashtbl.t;
      (** Overload sets keyed by function name. Written by [Env.add_overload]
      when a module's imports register paired pure/impure signatures or
      cross-module function name collisions. Read by [Env.get_overloads]
      / [Env.resolve_overload] during call-site dispatch. *)
  impl_index : (string, Env_types.impl_instance list) Hashtbl.t;
      (** Impls indexed by trait name. Written by [Env.add_impl]. Read by
      Env's trait-obligation resolver / trait-method dispatch. *)
  ufcs_methods : (string, Env_types.overload_entry list) Hashtbl.t;
      (** Method-only functions (accessible via UFCS but not as bare
      names). Written by [Env.add_ufcs_method] when a type import
      auto-registers its module's applicable methods. Read by
      [Env.lookup_ufcs_methods] during dot-call dispatch. *)
  mutable builtins_populated : bool;
      (** Guard: set by [Env_builtins.with_builtins] after it finishes
      registering builtin impls ([Integer for Int], [Equatable for
      String], …). Subsequent [with_builtins] calls on this session
      skip impl registration so [impl_index] doesn't accumulate
      duplicates.

      Written only on the happy path — if [with_builtins] raises
      partway through, the flag stays [false] and the next call
      re-runs the (idempotent) scope-symbol additions plus any impls
      that hadn't yet fired, potentially duplicating impls that
      already landed before the raise. In practice [with_builtins] is
      pure record/list/Hashtbl ops and cannot raise, so this edge
      case is theoretical. *)
  mutable def_id_counter : int;
      (** Fresh [def_id] counter. Monotonically increasing within a
      session; a new session starts at 0. [Session.mint_def_id]
      increments and returns the next id. See
      [Env_types.def_id] for the design. *)
  (* -- Inference state (lives for a single function body) -- *)
  mutable fresh_meta_counter : int;
      (** Next unused [TyMeta] id. Only ever incremented; never decreases
      within a body. Reset by [reset_meta]. *)
  mutable meta_origin : (int * string) list;
      (** [(meta_id, origin_type_param_name)] — recorded at [fresh_meta]
      time. Used only by error messages to say "instantiated for T". *)
  meta_env : (int, type_expr) Hashtbl.t;
      (** Meta-id → its bound type. [None] (i.e. not in the table) = unbound.
      Unbound metas post-inference are "cannot infer" errors. *)
  (* -- Core IR pass counters (per-compilation scratch state) -- *)
  mutable lower_destruct_counter : int;
      (** Next [__dt_N] id used by [Core_lower] when desugaring tuple
      destructuring patterns into [let __dt = e in …]. *)
  mutable lower_param_counter : int;
      (** Next [__p_N] id used by [Core_lower] when generating pattern-
      parameter temps for nested patterns in function params. *)
  mutable lower_question_bind_counter : int;
      (** Next [__qb_N] id used by [Core_lower] when desugaring direct [?=]
      binds into [CLet]/[CMatchArms] chains. *)
  mutable desugar_counter : int;
      (** Next fresh-id used by [Core_desugar] for CRecordUpdate
      temporaries and string-interp rewriting. *)
  mutable ssa_mut_counter : int;
      (** Next [_vN] version used by [Core_ssa] to SSA-rename mutable
      variables during straight-line reassignment unrolling. *)
      (* Lexer state is NOT on the session — see the lexer-state comment
     above the module loading section. *)
}
(** The full compilation session. See file header for lifetime rules. *)

(** Create a fresh session with empty everything. *)
let create () : t =
  {
    search_paths = [];
    package_roots = [];
    module_cache = Hashtbl.create 16;
    parse_cache = Hashtbl.create 16;
    type_index = Hashtbl.create 32;
    trait_index = Hashtbl.create 32;
    std_override_dir = None;
    std_override_active = false;
    std_source_dir = None;
    load_errors = [];
    prelude_modules_loaded = false;
    overloads = Hashtbl.create 32;
    impl_index = Hashtbl.create 16;
    ufcs_methods = Hashtbl.create 32;
    builtins_populated = false;
    def_id_counter = 0;
    fresh_meta_counter = 0;
    meta_origin = [];
    meta_env = Hashtbl.create 64;
    lower_destruct_counter = 0;
    lower_param_counter = 0;
    lower_question_bind_counter = 0;
    desugar_counter = 0;
    ssa_mut_counter = 0;
  }

(** Reset per-compilation counters. Called by [Core_pipeline] at the
    start of each compile so fresh-name generation doesn't accumulate
    across independent invocations within the same process (batch
    test runner, REPL, long-lived LSP session). *)
let reset_core_counters (s : t) : unit =
  s.lower_destruct_counter <- 0;
  s.lower_param_counter <- 0;
  s.lower_question_bind_counter <- 0;
  s.desugar_counter <- 0;
  s.ssa_mut_counter <- 0;
  (* Reset [def_id_counter] too so repeated compiles of the same source yield
     identical mangled symbols. Without the reset, a second compile produces
     shifted DefIds and different
     C output, breaking [Test_backend.explicit_backend_roundtrips]
     and any future output-cache checks. Typecheck-time DefIds
     ([ol_def_id] / [ii_def_id] / [td_def_id]) are not affected —
     those are minted during module load, which happens before
     [Core_pipeline.compile_typed] runs. *)
  s.def_id_counter <- 0

(** Mint a fresh [def_id] from the session counter. Monotonic within
    a session; a new session starts from 0. See [Env_types.def_id]. *)
let mint_def_id (s : t) : Env_types.def_id =
  let id = s.def_id_counter in
  s.def_id_counter <- id + 1;
  id

(** Clear inference state. Call at the start of each function body
    (HM semantics: meta variables are per-body). *)
let reset_meta (s : t) : unit =
  s.fresh_meta_counter <- 0;
  s.meta_origin <- [];
  Hashtbl.clear s.meta_env

(* ============================================================================
   Trait registry
   ============================================================================

   See [trait_index]'s docstring. Registration happens from
   [Modules.load_module] once a module has been parsed and cached;
   lookup is consumed by [Env.get_trait]'s miss fallback so the
   supertrait graph is globally resolvable regardless of the current
   file's [import:] list. *)

(** Register every public [DTrait] decl in a loaded module into the
    session's [trait_index]. Private traits ([DPrivate (DTrait _)]) are
    skipped — they stay module-scoped by the language's privacy rule.

    Conflict detection (step 4): if the name was previously registered
    by a DIFFERENT module, surface an error into [sess.load_errors] so
    the pipeline can relay it through the normal diagnostic channel.
    Re-registration by the same module (same canonical name) is
    idempotent — that's the expected case when a module is loaded
    via multiple import chains within the same compilation.

    Env-level structural equality ([Env.trait_defs_structurally_equal])
    catches finer-grained conflicts at the per-file registration path.
    Session-level detection here is the cross-module cousin: two
    independent modules declaring the same trait name are the
    diamond the user must break, regardless of whether the
    signatures happen to coincide structurally. *)
let register_module_traits (sess : t) (m : loaded_module) : unit =
  List.iter
    (fun (d : decl) ->
      match d.decl_desc with
      | DTrait trait -> (
          match Hashtbl.find_opt sess.trait_index trait.trait_name with
          | Some prior when prior <> m.name ->
              let msg =
                Printf.sprintf
                  "conflicting trait declaration: '%s' is declared in both \
                   '%s' and '%s' — pick one home module for the trait or \
                   rename one of them"
                  trait.trait_name prior m.name
              in
              let err =
                {
                  message = msg;
                  loc = d.decl_loc;
                  phase = TypeCheck;
                  kind = OtherError;
                  notes = [];
                  help =
                    Some
                      (Printf.sprintf
                         "trait names are globally unique in blorp; if these \
                          are intended to be independent traits, rename one \
                          (e.g. '%s' / '%sExt')"
                         trait.trait_name trait.trait_name);
                }
              in
              sess.load_errors <- err :: sess.load_errors
          | Some _ -> () (* same module re-registering: idempotent *)
          | None -> Hashtbl.replace sess.trait_index trait.trait_name m.name)
      | _ -> () (* DPrivate and everything else: skip *))
    m.decls

(** Find a trait's AST decl + owning module by name. [None] if the name
    is unregistered (either never loaded or hidden behind [DPrivate]). *)
let find_trait_decl (sess : t) (name : string) :
    (trait_decl * loaded_module) option =
  match Hashtbl.find_opt sess.trait_index name with
  | None -> None
  | Some mod_name -> (
      match Hashtbl.find_opt sess.module_cache mod_name with
      | None -> None (* index out of sync with cache — treat as miss *)
      | Some m ->
          List.find_map
            (fun (d : decl) ->
              match d.decl_desc with
              | DTrait trait when trait.trait_name = name -> Some (trait, m)
              | _ -> None)
            m.decls)

(** Walk a loaded module and register every declared type (union, enum,
    record) into [sess.type_index] with the module as its home. Private
    types ([DPrivate (DType _)] or [DPrivate (DRecord _)]) are NOT
    registered — they're module-scoped and can't be referenced from
    other modules, so they shouldn't appear in cross-module diagnostics.
    Re-registration is idempotent when the module matches; a
    conflicting module would indicate a name collision we don't try to
    flag here (typecheck's import layer handles that). *)
let register_module_types (sess : t) (m : loaded_module) : unit =
  List.iter
    (fun (d : decl) ->
      match d.decl_desc with
      | DType td -> (
          match Hashtbl.find_opt sess.type_index td.type_name with
          | Some prior when prior = m.name -> () (* idempotent re-register *)
          | _ -> Hashtbl.replace sess.type_index td.type_name m.name)
      | DRecord rd -> (
          match Hashtbl.find_opt sess.type_index rd.record_name with
          | Some prior when prior = m.name -> ()
          | _ -> Hashtbl.replace sess.type_index rd.record_name m.name)
      | _ -> ())
    m.decls

(** Look up a type's home module in the session's [type_index].
    Returns [None] for builtins / unregistered names — callers should
    render bare in that case. *)
let find_type_home (sess : t) (name : string) : string option =
  Hashtbl.find_opt sess.type_index name

(* ============================================================================
   Ambient "current session"
   ============================================================================

   Most type-system predicates ([Types.types_compatible], [head_resolve],
   etc.) need meta-env access but are called from many call sites that
   don't naturally carry a session — Env's trait-obligation resolver,
   trait resolution inside codegen, the test helpers. Threading [~sess]
   through {i every} transitive caller would touch 150+ sites for no
   observable behavior change.

   Instead, the meta-env-consuming functions in [Types] default to the
   ambient current session when [~sess] is not explicitly passed. The
   frontend entry points ([Pipeline.compile], [Typecheck.typecheck],
   [Lsp_state] per-document handlers) scope their work with
   [with_current] so every nested call sees the right session.

   {1 Rules}

   - Multiple {b sequential} sessions work: wrap each operation in
     [with_current sess (fun () -> ...)].
   - Multiple {b concurrent} sessions in the same OCaml domain do NOT
     work — the ambient ref is shared. Use explicit [~sess] arguments
     for concurrent-from-OCaml cases (spawning a [Thread.t] per
     compile, for instance).
   - The [Session.t] itself is the single source of truth; the ambient
     ref just saves callers from threading it.

   Parallelism across OCaml 5 domains is out of scope for this phase. *)

(** The ambient current session. Starts as a fresh empty session so
    module initialization (e.g. [Env_builtins]) that calls into [Types]
    during setup doesn't trip over a [None] ref. *)
let current_ref : t ref = ref (create ())

(** Depth of nested [with_current] frames currently on the stack.
    [assert_in_scope] uses this to detect callers that read [current ()]
    without an explicit frame — those callers are using the long-lived
    process default, which silently shares state across what should be
    isolated boundaries. *)
let scope_depth : int ref = ref 0

(** Get the ambient session. *)
let current () : t = !current_ref

(** Run [f ()] with [s] as the ambient session. Restores the previous
    ambient on exit (via [Fun.protect], so exceptions also restore). *)
let with_current (s : t) (f : unit -> 'a) : 'a =
  let prev = !current_ref in
  current_ref := s;
  incr scope_depth;
  Fun.protect
    ~finally:(fun () ->
      decr scope_depth;
      current_ref := prev)
    f

(** Debug guard: raises [Failure] when called outside any [with_current]
    frame. Catches latent aliasing — every read of the ambient session
    should be inside a deliberate scope, otherwise the caller is
    silently reusing the process default. Cheap; called from test
    fixtures and (eventually) debug builds. *)
let assert_in_scope () : unit =
  if !scope_depth = 0 then
    failwith "Session.assert_in_scope: no with_current frame active"
