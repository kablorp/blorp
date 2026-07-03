(** Type Utilities for blorp Type Checker

    Provides type manipulation functions including:
    - Type variable generation
    - Substitution maps
    - Type comparison and compatibility
    - Type-to-string conversion

    {1 Session threading (Phase 2.1)}

    Meta-variable state ([fresh_meta_counter], [meta_origin], [meta_env])
    lives on [Session.t] — all functions that touch it take [~sess].
    Reset between function bodies via [Session.reset_meta]. Helpers that
    don't touch meta state (e.g. [types_equal], [type_to_string]) are
    session-free.
*)

open Ast

type subst_entry = { var_name : string; concrete_type : type_expr }
(** Type substitution map entry *)

type subst_map = subst_entry list
(** Type substitution map *)

val type_to_string : type_expr -> string
(** Convert a type expression to a human-readable string *)

val normalize_type_name : string -> string
(** Legacy named tensor-family normalizer. New source-level array types use
    [TyArray], but old internal paths may still call this while being ported. *)

val array_head_name : string
(** Structural array helpers. *)

val ty_array : type_expr -> type_expr list -> type_expr
val is_array_type : type_expr -> bool
val array_parts : type_expr -> (type_expr * type_expr list) option

val types_equal : type_expr -> type_expr -> bool
(** Check if two types are structurally equal *)

val strip_type_param_bounds : string -> string
(** Strip trait bounds from type parameter name: "T:Stringable" -> "T" *)

val is_type_param_name : string -> bool
(** True for parser-encoded type parameter names that may include inline trait
    bounds, using the legacy single-uppercase [TyNamed] compatibility rule. *)

val is_valid_named_type_param : string -> bool
(** True when a type parameter name starts with a capital ASCII letter and
    contains only ASCII letters/digits. Trait bounds may be present. *)

val is_valid_dim_type_param : string -> bool
(** True for dimension parameter names like [#N] or [#Rows]. [#_] is accepted
    as the wildcard dimension parameter. *)

val types_compatible :
  ?sess:Session.t -> ?type_params:string list -> type_expr -> type_expr -> bool
(** Check if two types are compatible (for assignment/passing).
    More permissive than equality — e.g., pure functions can be passed
    where impure is expected.
    @param type_params explicit list of type parameter names in scope *)

val types_bidirectional :
  ?sess:Session.t -> ?type_params:string list -> type_expr -> type_expr -> bool
(** Check if two types are bidirectionally compatible (true unification).
    Unlike [types_compatible] which only matches left->right, this allows
    type variables/params on either side to bind in a single substitution context.
    Note: function purity checking is still position-dependent (pure->impure ok,
    impure->pure rejected regardless of direction).
    @param type_params explicit list of type parameter names in scope *)

val types_compatible_rigid :
  ?sess:Session.t -> rigid_vars:string list -> type_expr -> type_expr -> bool
(** Check type compatibility with rigid type variables (for generic body checking) *)

val validate_array_dims :
  ?sess:Session.t -> string list -> type_expr -> string option
(** Validate array dimension arguments. Returns None if valid,
    Some error_message if any dimension arg is not a valid dimension type. *)

val collect_type_vars : type_expr -> string list
(** Collect free type variable names from a type expression *)

val collect_type_param_candidates : type_expr -> string list
(** Collect source-level names that may auto-generalize to type parameters.
    Callers must still filter concrete types with the environment. *)

val map_type_expr : (type_expr -> type_expr option) -> type_expr -> type_expr
(** Generic recursive mapper for type expressions (bottom-up, single-pass) *)

val instantiate_type_params : string list -> type_expr -> type_expr
(** Instantiate type parameter names as TyVar in a type expression *)

val freshen_dim_wildcards : ?sess:Session.t -> type_expr -> type_expr
(** Replace each occurrence of [TyVar "#_"] with a fresh [TyMeta]. Each
    occurrence is an independent wildcard. Applied at call-site signature
    instantiation (not at registration) so per-call freshness is preserved. *)

val lookup_subst : string -> subst_map -> type_expr option
(** Look up a type variable in the substitution map *)

val occurs_in : ?sess:Session.t -> string -> type_expr -> bool
(** Check if a type variable occurs in a type (for occurs check) *)

val apply_subst : ?sess:Session.t -> subst_map -> type_expr -> type_expr
(** Apply substitutions to a type *)

val apply_type_param_subst : (string * type_expr) list -> type_expr -> type_expr
(** Apply a type-parameter substitution, accepting either raw bound-bearing
    names such as [T:Stringable] or their stripped names as substitution keys. *)

val unify :
  ?sess:Session.t ->
  ?symmetric:bool ->
  ?type_params:string list ->
  ?rigid_vars:string list ->
  type_expr ->
  type_expr ->
  subst_map option
(** Unify two types, returning accumulated substitutions on success *)

(** {1 Meta variables (HM unification variables)}

    [TyMeta n] is a unification variable with unique integer identity,
    distinct from rigid [TyVar] (user-declared type parameters). Metas are
    created at call-site instantiation, bound eagerly during [unify], and
    resolved via [zonk_type] at end-of-body. An unbound meta surviving
    zonking is a "cannot infer" error — downstream passes never see one.

    Meta state lives on [Session.t]; reset via [Session.reset_meta]. *)

val fresh_meta : ?sess:Session.t -> ?origin:string -> unit -> type_expr
(** Create a fresh meta with an origin name (the rigid type-param being
    instantiated, e.g. "T" / "K") recorded for error messages. *)

val lookup_meta : ?sess:Session.t -> int -> type_expr option
(** Look up a meta's current binding in the env. *)

val meta_origin_name : ?sess:Session.t -> int -> string
(** Return the origin name recorded when a meta was created. *)

val bind_meta : ?sess:Session.t -> int -> type_expr -> unit
(** Bind a meta to a type. Caller verifies [occurs_meta] first. *)

val occurs_meta : ?sess:Session.t -> int -> type_expr -> bool
(** Does [ty] contain [TyMeta n] (following meta chains)? *)

val zonk_type : ?sess:Session.t -> type_expr -> type_expr
(** Resolve every [TyMeta] through the env to its final binding. Idempotent. *)

val contains_meta : type_expr -> bool
(** Does [ty] contain any inference-only [TyMeta]? Used to enforce typed
    frontend/Core phase boundaries after zonking. *)

val head_resolve : ?sess:Session.t -> type_expr -> type_expr
(** Head-resolve a type: follow [TyMeta] chains through the session one
    hop at a time, without recursing into arguments. *)

val resolve_bound_metas : ?sess:Session.t -> type_expr -> type_expr
(** Resolve every bound [TyMeta] through the env while preserving unbound metas
    as inference constraints. *)

val ty_int : type_expr
(** Built-in type constructors *)

val ty_float : type_expr
val ty_string : type_expr
val ty_bool : type_expr
val ty_char : type_expr
val ty_void : type_expr

val ty_int8 : type_expr
(** Sized integer type constructors *)

val ty_int16 : type_expr
val ty_int32 : type_expr
val ty_int128 : type_expr
val ty_uint8 : type_expr
val ty_uint16 : type_expr
val ty_uint32 : type_expr
val ty_uint64 : type_expr
val ty_uint128 : type_expr

val ty_float32 : type_expr
(** Sized float type constructors *)

val ty_float16 : type_expr

val all_int_type_names : string list
(** All sized integer type names (including Int) *)

val is_any_integer_type : type_expr -> bool
(** Check if a type is any integer type (signed or unsigned, any width).
    Follows [TyMeta] one hop via the ambient session so pre-zonk
    callers get the right answer without explicit threading. *)

val is_std_duration_type : type_expr -> bool
(** Check if a type is the std/units Duration type. Follows [TyMeta] one hop
    via the ambient session, matching the integer predicate behavior above. *)

val is_signed_integer_type : type_expr -> bool
(** Check if a type is a signed integer type. *)

val is_unsigned_integer_type : type_expr -> bool
(** Check if a type is an unsigned integer type. *)

val int_type_to_c : string -> string
(** Map integer type name to C type string *)

val int_type_range : string -> int64 * int64
(** Range for compile-time literal checking *)

val all_float_type_names : string list
(** All float type names *)

val is_any_float_type : type_expr -> bool
(** Check if a type is any float type (Float, Float32, or Float16).
    Follows [TyMeta] one hop via the ambient session. *)

val is_float32_type : type_expr -> bool
(** Check if a type is Float32. *)

val is_float16_type : type_expr -> bool
(** Check if a type is Float16. *)

val float_type_to_c : string -> string
(** Map float type name to C type string *)

val ty_list : type_expr -> type_expr
(** Create a List type *)

val ty_func : ?pure:bool -> type_expr list -> type_expr -> type_expr
(** Create a function type *)

val is_std_module_name : string -> bool
(** True for stdlib module identities. *)

val is_global_abi_type_name : string -> bool
(** True for type names whose runtime/language ABI is intentionally global.
    Stdlib modules may declare these without receiving a module-qualified
    identity; all other std types remain module-owned. *)

val is_runtime_erased_payload_union_type_name : string -> bool
(** True for union types whose payloads are constructed from runtime-erased
    [void*] slots and therefore must keep erased payload storage until a
    dedicated typed bridge exists. *)

val canonical_module_type_name : module_path:string -> string -> string
(** Canonical frontend identity for a type owned by a module. Stdlib ABI
    types intentionally remain bare; other std-local types are owner-qualified
    like user module types. *)

val split_canonical_module_type_name : string -> (string * string) option
(** Split a canonical module-owned type name into [(module_path, type_name)]. *)

val qualify_module_local_types :
  module_path:string -> string list -> type_expr -> type_expr
(** Rewrite module-local type references to canonical owner-qualified names. *)

val resolve_qualified_types : (string * string) list -> type_expr -> type_expr
(** Resolve qualified type names (e.g., "A.Thing" → canonical module-owned
    type; stdlib aliases like "D.Dict" → "Dict") using module aliases. *)

(** {1 Dim — consolidated dimension-type API}

    Dimension types ([TyConstInt], [TyVar "#N"], [TyVarDims], [TyRange],
    [TyDimOp]) are a refinement of [Int]. This module is the single source
    of truth for dim predicates, lifts, and normalizations. See
    [memory/dim_types_formalization.md] for the 8 laws this API enforces. *)
module Dim : sig
  val is_var_name : string -> bool
  (** Prefix check for dim-var names. Replaces inline [name.[0] = '#'] checks. *)

  val is_dim : ?sess:Session.t -> string list -> type_expr -> bool
  (** True if [ty] is any dimension form. [type_params] is needed to
      recognize parser-produced [TyNamed (name, [])] where [name] is a
      dim param in scope. *)

  val is_value_dim : type_expr -> bool
  (** True if [ty] is a scalar dimension/refinement value that erases to
      [Int] at runtime. Excludes [TyVarDims], which is a type-level pack. *)

  val find_negative : type_expr -> int option
  (** Law 2: find the first negative concrete dim value in [ty]. *)

  val lift_to_int : type_expr -> type_expr
  (** Law 3: lift a dim or refinement to [Int] for value-context operations. *)

  val contains_vardims : type_expr -> bool
  (** Law 7: does [ty] contain any [TyVarDims] anywhere? *)

  val collect_vardim_names : type_expr -> string list
  (** Law 7: extract the names of all [TyVarDims] occurrences in [ty]. *)

  val normalize : type_expr -> type_expr
  (** Law 8: normalize dim arithmetic, evaluating concrete ops to [TyConstInt]. *)
end
