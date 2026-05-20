(** Environment/Symbol Table for blorp Type Checker

    Provides scoped symbol lookup for:
    - Variable types
    - Function signatures
    - Type declarations (unions, records)
    - Type aliases
    - Trait bounds
*)

open Ast

(** Explicit mutability for variable bindings *)
type var_mutability = Immutable | Mutable

(** Origin of a variable binding — used for context-specific error messages and
    phase-local capability checks. *)
type var_origin =
  | LetBinding
  | FuncParam
  | BorrowedResourceParam
  | ForLoopVar
  | MatchBinding
  | ScopedResource
  | ScopedResourceDerived
  | Other

(** These shared types live in [Env_types] to avoid a circular library
    dependency (Session needs [overload_entry] / [impl_instance] to hold
    its hashtables; Env depends on Session). Re-exported here so
    [Env.purity], [Env.overload_entry], etc. continue to resolve. *)
type purity = Env_types.purity = Pure | Impure

type func_origin = Env_types.func_origin = UserDefined | Builtin | Foreign
type def_id = Env_types.def_id

type resource_result_policy = Env_types.resource_result_policy =
  | ResourceResultDependent
  | ResourceResultOrdinary

type resource_arg_policy = Env_types.resource_arg_policy =
  | RejectResourceArgs
  | AllowResourceArgs of resource_result_policy

type loop_producer = Env_types.loop_producer =
  | LoopProducerIndices
  | LoopProducerEnumerate
  | LoopProducerEnumerate2
  | LoopProducerWindows

type trait_ref = Env_types.trait_ref = { tr_name : string }
(** Reference to a trait in a bound or obligation.

    Trait references are still bare names at the language surface today.
    [Generic_params] owns the structured representation so later phases have a
    place to add trait arguments without continuing the "T:Trait"
    string-encoding pattern. *)

type bound_type_param = Env_types.bound_type_param = {
  param_name : string;
  param_bounds : trait_ref list;
}
(** Type parameter with optional trait bounds *)

type type_kind = TypeUnion | TypeEnum | TypeBuiltin | TypeResource

type overload_entry = Env_types.overload_entry = {
  ol_def_id : def_id;
  ol_func_type : type_expr;
  ol_type_params : bound_type_param list;
  ol_param_names : string option list;
  ol_purity : purity;
  ol_origin : func_origin;
  ol_resource_args : resource_arg_policy;
  ol_module_path : string option;
  ol_dim_constraints : (type_expr * type_expr) list;
  ol_loop_producer : loop_producer option;
  ol_debug_only : bool;
}

(** Symbol kinds *)
type symbol_kind =
  | VarSymbol of {
      var_type : type_expr;
      source_type : type_expr option;
      mutability : var_mutability;
      origin : var_origin;
      refinement : Refinement.binding_refinement;
    }
  | FuncSymbol of {
      callable_id : def_id;
      func_type : type_expr;
      type_params : bound_type_param list;
      param_names : string option list;
      purity : purity;
      origin : func_origin;
      resource_args : resource_arg_policy;
      module_path : string option;
      dim_constraints : (type_expr * type_expr) list;
      loop_producer : loop_producer option;
      debug_only : bool;
    }
  | TypeSymbol of {
      type_params : string list;
      variants : variant list;
      type_kind : type_kind;
    }
  | RecordSymbol of {
      type_params : string list;
      fields : field_decl list;
      is_value : bool;
    }
  | AliasSymbol of { type_params : string list; target : type_expr }
  | ConstructorSymbol of {
      parent_type : string;
      constructor_id : int;
      type_params : string list;
      field_types : type_expr list;
      tag : int;
    }

type symbol = { name : string; kind : symbol_kind }
(** Symbol table entry *)

type scope = symbol list
(** A scope contains symbols *)

type trait_obligation = {
  obligation_type : type_expr;
  obligation_trait : trait_ref;
}
(** A pending proof that [obligation_type] satisfies [obligation_trait]. *)

(** Result of resolving a trait obligation.

    [TraitObligationDeferred] is used for unresolved inference variables whose
    final concrete type is not known in the current phase. Callers that run
    before monomorphization should preserve today's behavior and defer those. *)
type trait_obligation_resolution =
  | TraitObligationSatisfied
  | TraitObligationUnsatisfied
  | TraitObligationDeferred

type trait_method_sig = {
  tm_name : string;
  tm_params : type_expr list;
  tm_return : type_expr;
  tm_is_pure : bool;
  tm_has_default : bool;
  tm_default_body : Ast.expr option;
  tm_param_names : string option list;
}
(** Trait method signature *)

type trait_def = {
  td_def_id : def_id;
  td_name : string;
  td_type_params : string list;
  td_supertraits : string list;
  td_methods : trait_method_sig list;
  td_loc : loc option;
  td_module_path : string option;
}
(** Trait definition.

    [td_loc] is the source location of the declaration when known;
    [env_builtins] uses [None] for its pre-registered trait stubs. The
    orphan-rule check (Phase 3.4) consults [td_loc.loc_file] to
    determine which module owns the trait.

    [td_module_path] is the logical module this trait was declared in,
    using the same form as [overload_entry.ol_module_path] (e.g.
    ["std/traits"] / ["my/mod"]). [None] for [env_builtins] stubs that
    aren't sourced from a single module. Used for diagnostics when a
    duplicate trait declaration is rejected — points at both the new
    and existing declaration's home module. *)

type impl_instance = Env_types.impl_instance = {
  ii_def_id : def_id;
  ii_trait : string;
  ii_for_type : type_expr;
  ii_bounds : bound_type_param list;
  ii_is_builtin : bool;
  ii_loc : loc option;
}
(** Impl instance.

    [ii_is_builtin] distinguishes typecheck-only registrations from
    [env_builtins] (which never emit C) from source-level impls (which
    do). The coherence check only reports conflicts between source-level
    impls, since only those cause actual C symbol collisions.

    [ii_loc] is the source location of the impl declaration when known;
    [env_builtins] uses [None] since its impls have no source site. The
    coherence diagnostic cites this when rejecting a candidate. *)

type env = {
  scopes : scope list;
  current_function : string option;
  current_function_pure : bool;
  type_params_in_scope : string list;
  type_param_bounds : bound_type_param list;
  trait_functions : (string * string) list;
  traits : trait_def list;
  impls : impl_instance list;
  impl_index : (string, impl_instance list) Hashtbl.t;
  overloads : (string, overload_entry list) Hashtbl.t;
  ufcs_methods : (string, overload_entry list) Hashtbl.t;
}
(** Environment is a stack of scopes *)

val empty : unit -> env
(** Construct a fresh empty environment. The returned env's [impl_index],
    [overloads], and [ufcs_methods] fields alias [Session.current ()]'s
    tables — writes through the env affect the session and are visible
    to every other env derived from the same session, but isolated from
    envs derived under a different [Session.with_current] frame. *)

val push_scope : env -> env
(** Push a new scope *)

val add_symbol : env -> symbol -> env
(** Add a symbol to the current scope *)

val lookup_in_current_scope : env -> string -> symbol option
(** Look up a symbol in the current (topmost) scope only *)

val lookup : env -> string -> symbol option
(** Look up a symbol by name in all scopes *)

val symbol_kind_label : symbol -> string
(** Human-readable label for a symbol kind, used in error messages *)

val add_var :
  env ->
  string ->
  type_expr ->
  ?source_type:type_expr ->
  ?mutability:var_mutability ->
  ?origin:var_origin ->
  ?refinement:Refinement.binding_refinement ->
  unit ->
  env
(** Add a variable to the environment *)

val is_func_param : env -> string -> bool
(** Check if a variable is a function parameter *)

val is_for_loop_var : env -> string -> bool
(** Check if a variable is a for-loop variable *)

val is_scoped_resource_var : env -> string -> bool
(** Check if a variable is a scoped resource binding. *)

val is_scoped_resource_derived_var : env -> string -> bool
(** Check if a variable is derived from a scoped resource binding. *)

val is_scoped_resource_related_var : env -> string -> bool
(** Check if a variable is either a scoped resource or a value derived from one. *)

val add_func :
  env ->
  string ->
  type_expr ->
  ?callable_id:def_id ->
  ?type_params:bound_type_param list ->
  ?param_names:string option list ->
  ?purity:purity ->
  ?origin:func_origin ->
  ?resource_args:resource_arg_policy ->
  ?module_path:string ->
  ?dim_constraints:(type_expr * type_expr) list ->
  ?loop_producer:loop_producer ->
  ?debug_only:bool ->
  unit ->
  env
(** Add a function to the environment *)

val is_debug_only_func : env -> string -> bool
(** True when [name] resolves to a function explicitly declared @debug_only. *)

val is_debug_only_overload_set : env -> string -> bool
(** True when [name] has overload entries and every registered overload is
    explicitly declared @debug_only. *)

val add_type :
  ?with_ctors:bool ->
  ?kind:type_kind ->
  env ->
  string ->
  string list ->
  variant list ->
  env
(** Add a type declaration to the environment *)

val add_record :
  env ->
  string ->
  string list ->
  field_decl list ->
  ?is_value:bool ->
  unit ->
  env
(** Add a record declaration to the environment *)

val is_value_record : env -> string -> bool
(** Check if a record type is a value type (struct) *)

val add_alias : env -> string -> string list -> type_expr -> env
(** Add a type alias to the environment *)

val get_var_type : env -> string -> type_expr option
(** Get the type of a variable *)

val get_var_refinement : env -> string -> Refinement.binding_refinement option
(** Get refinement metadata attached to a variable binding. *)

val set_var_refinement :
  env -> string -> Refinement.binding_refinement -> env option
(** Return a copy of the environment with the nearest variable binding's
    refinement metadata replaced. Returns [None] when the name does not resolve
    to a variable binding. *)

val get_func_info :
  env -> string -> (type_expr * bound_type_param list * purity) option
(** Get a function's info: (type, type_params, purity) *)

val get_func_callable_id : env -> string -> def_id option
(** Get the canonical declaration identity for the function currently resolved
    by [name]. *)

val get_func_loop_producer : env -> string -> loop_producer option
(** Get the compiler loop-producer identity for the function currently
    resolved by [name], if it is one. *)

val get_dim_constraints : env -> string -> (type_expr * type_expr) list
(** Get a function's dimension constraints from its where clause *)

val is_builtin_func : env -> string -> bool
(** Check if a function name resolves to a compiler builtin (not user-defined) *)

val is_local_func : env -> string -> bool
(** Check if a function name resolves to a lexical, non-builtin function in
    the current compilation unit. Such functions shadow imported overloads. *)

val get_func_param_names : env -> string -> string option list option
(** Get a function's parameter names in declaration order (if known) *)

val get_type_decl : env -> string -> (string list * variant list) option
(** Get a type declaration: (type_params, variants) *)

val get_type_kind : env -> string -> type_kind option
(** Get a type declaration's explicit kind *)

val get_constructor :
  env -> string -> (string * string list * type_expr list * int) option
(** Get a constructor: (parent_type, type_params, field_types, tag) *)

val get_constructor_callable_id : env -> string -> int option
(** Get the callable identity for a constructor call. *)

val get_record : env -> string -> (string list * field_decl list) option
(** Get a record: (type_params, fields) *)

val find_records_with_fields : env -> string list -> string list
(** Find all record/struct type names whose field names exactly match the given set *)

val get_alias : env -> string -> (string list * type_expr) option
(** Get a type alias: (type_params, target) *)

val disambiguate_nominal_dim_application : env -> type_expr -> type_expr
(** Reinterpret parser-produced [Name[#N]] array suffix syntax as nominal type
    application when [Name] is a record, union, or alias whose parameters are
    all dimension parameters. *)

val resolve_alias : env -> type_expr -> type_expr
(** Resolve a type alias (recursively, with cycle detection) *)

val function_type_purity : env -> type_expr -> purity option
(** Resolve aliases and classify a type as a pure/impure function type, if it is
    one. *)

val is_impure_function_type : env -> type_expr -> bool
(** True when [function_type_purity] resolves to [Impure]. *)

val enter_function : env -> string -> bool -> string list -> env
(** Enter a function context *)

val get_type_params : env -> string list
(** Get the current type parameters in scope *)

val trait_function_collision : env -> string -> string -> string option
(** Detect whether registering [(func_name, trait_name)] would collide
    with an existing binding to a different trait. Idempotent
    re-registration of the same pair is not a collision. *)

val add_trait_function : env -> string -> string -> env
(** Register a trait function (maps function name to its trait). Does
    not collision-check; callers wanting diagnostics should first
    consult [trait_function_collision]. *)

val get_function_trait : env -> string -> string option
(** Get the trait that a function belongs to *)

val type_param_name : string -> string
(** Return the declared type parameter name without any parser-level trait
    bound encoding. *)

val type_param_names : string list -> string list
(** Return declared type parameter names without parser-level trait bound
    encoding. *)

val bound_type_param_names : bound_type_param list -> string list
(** Return declared names from structured bounded type params. *)

val overload_type_param_names : overload_entry -> string list
(** Return declared type parameter names for an overload's structured generic
    parameter list. *)

val trait_obligation : type_expr -> string -> trait_obligation
(** Build a trait obligation from a type and parser-level trait name. *)

val trait_obligations_for_bound_type_param :
  bound_type_param -> type_expr -> trait_obligation list
(** Generate obligations for applying a bounded type parameter to a concrete type. *)

val set_type_param_bounds : env -> bound_type_param list -> env
(** Set type parameter bounds for the current context *)

val has_trait_bound : env -> string -> string -> bool
(** Check if a type parameter has a specific trait bound *)

val has_trait_bound_transitive : env -> string -> string -> bool
(** Check if a type parameter satisfies a trait bound transitively (through supertraits) *)

val trait_method_names_transitive : env -> string -> string list
(** All method names reachable from [trait_name] through its own
    declaration + the transitive supertrait graph. Cycle-safe. Used
    by default-body synthesis to identify trait-method references
    that should be rewritten into UFCS form. *)

val trait_methods_with_declaring_trait : env -> string -> (string * string) list
(** Like [trait_method_names_transitive] but returns each method
    paired with the trait that declares it. Needed when registering
    trait-function bindings for an imported trait that has
    supertraits — each inherited method must bind to its declaring
    trait for correct dispatch. *)

val trait_has_supertrait : env -> string -> string -> bool
(** Check if a trait has another trait as a supertrait (transitively) *)

val find_trait_method_for_param :
  env -> string -> string -> (trait_method_sig * string) option
(** Look up a trait method for a bounded type parameter (searches bounds + supertraits) *)

val add_trait : env -> trait_def -> env
(** Register a trait definition *)

val trait_defs_structurally_equal : trait_def -> trait_def -> bool
(** Structural equality for trait definitions. Compares name, type
    params, supertraits, and method signatures. Ignores [td_loc] and
    [td_module_path] — those are provenance metadata, not semantics. *)

val try_add_trait : env -> trait_def -> (env, string) result
(** Register a trait, rejecting conflicting redeclarations.

    [Ok env']: the trait was added, or an identical one was already
    present (idempotent case).
    [Error msg]: a trait by the same name exists but with different
    supertraits / methods. The message names both declaration sites
    when provenance is available. *)

val trait_def_of_decl :
  ?loc:loc -> ?module_path:string -> trait_decl -> trait_def
(** Convert a parsed [trait_decl] into a [trait_def]. Pure: no env or
    session side effects. Shared by [Typecheck.register_trait] (per-file
    registration path) and [get_trait]'s session fallback. *)

val get_trait : env -> string -> trait_def option
(** Look up a trait by name.

    Consults the per-file [env.traits] first; on miss, falls back to
    the session-scoped trait index populated by every
    [Modules.load_module] call. This is what makes the supertrait graph
    uniformly resolvable regardless of whether the current file imports
    the trait's home module. *)

val format_trait_name : env -> string -> string
(** Format a trait name for a diagnostic, qualifying with the trait's
    home module when known (builtin traits render bare). Used by
    error emitters to disambiguate which trait is being referenced. *)

val format_type_name : string -> string
(** Format a type name with its home module via session's type_index,
    or bare when the type is a builtin / registered in the current
    file. Track B. *)

val format_constructor_ref : env -> string -> string
(** Format a constructor reference — ["Some"] → ["Some (from std/option)"]
    when the parent type's home module is known. Track B. *)

val format_overload_ref : string -> overload_entry -> string
(** Format a single overload reference for a diagnostic, qualifying
    with the overload's home module when known. Track B's "which
    `map`?" disambiguator. *)

val format_overload_candidates : string -> overload_entry list -> string
(** Format a list of overload candidates as a bulleted, qualified
    list. Empty input returns the empty string. *)

val add_impl : env -> impl_instance -> env
(** Register an impl instance *)

val find_conflicting_impl : env -> impl_instance -> impl_instance option
(** Find a previously-registered impl that conflicts with [candidate]:
    same trait and bidirectionally-unifiable for-type. [None] if no overlap. *)

val type_implements_trait : env -> type_expr -> string -> bool
(** Check if a concrete type implements a trait *)

val type_satisfies_trait_obligation : env -> trait_obligation -> bool
(** Check whether a type satisfies a structured trait obligation. *)

val resolve_trait_obligation :
  env -> trait_obligation -> trait_obligation_resolution
(** Resolve a structured trait obligation. *)

val find_unsatisfied_trait_obligation :
  env -> trait_obligation list -> trait_obligation option
(** Return the first obligation that is definitely unsatisfied.

    Deferred obligations are ignored so pre-monomorphization callers can keep
    moving when a final concrete type is not yet known. *)

val resolve_self : type_expr -> type_expr -> type_expr
(** Substitute Self type with a concrete type in a type expression *)

val get_resolved_method_sig : trait_method_sig -> type_expr -> trait_method_sig
(** Get a trait method signature with Self resolved to a concrete type *)

val add_overload : env -> string -> overload_entry -> env
(** Register an overload entry for a function name *)

val get_overloads : env -> string -> overload_entry list
(** Get all overload entries for a function name *)

val find_overload_by_def_id : env -> def_id -> overload_entry option
(** Find a registered overload by its canonical def id. *)

val resolve_overload : env -> string -> type_expr -> overload_entry option
(** Resolve an overloaded function name given the first argument's type *)

val select_overload_for_args :
  overload_entry list -> type_expr list -> overload_entry option
(** Pick the best overload entry from a candidate list given an arg
    vector. Used by the UFCS dispatch in [infer.ml] (Phase 2.7 tasks
    48/49). Filters by first-arg head type, then by function-typed-param
    purity (param requires pure ⇒ arg must be pure; tiebreak prefers
    the more pure-required signature). *)

val ufcs_collision : env -> string -> overload_entry -> overload_entry option
(** Detect a cross-module UFCS collision before calling [add_ufcs_method].
    Returns [Some existing] when another module has already registered a
    UFCS method of the same [name], same first-arg head type, and same
    purity. Returns [None] otherwise (same module, different first-arg
    type, or missing module path). *)

val add_ufcs_method : env -> string -> overload_entry -> env
(** Register a method-only function (accessible via UFCS but not bare name) *)

val lookup_ufcs_methods : env -> string -> type_expr -> overload_entry list
(** Look up UFCS-only methods by name and first argument type *)

val has_ufcs_method : env -> string -> bool
(** Check if a name exists as a UFCS-only method *)

val levenshtein : string -> string -> int
(** Levenshtein edit distance between two strings *)

val find_similar : string -> env -> string option
(** Find a similar identifier. Returns Some "name" or None *)

val direct_subst : (string * type_expr) list -> type_expr -> type_expr
(** Direct (non-chaining) substitution for alias resolution *)
