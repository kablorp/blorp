(** Shared type definitions used by both [Env] and [Session].

    These types are pulled out of [env.ml] so that [session.ml] can hold
    overload and impl tables without creating a circular library
    dependency (Session → Env → Env, via [Env.empty] reading the ambient
    session's tables).

    [env.ml] re-exports each type via the [= { ... }] alias pattern so
    existing consumers that reference [Env.purity], [Env.overload_entry],
    etc. continue to work unchanged. *)

open Ast

type def_id = int
(** Globally-unique identifier for a declaration. Minted at
    registration time by [Session.mint_def_id]; stays stable within a
    compile (session) but restarts from 0 in each new session. Used to
    give every function / type / constructor / impl / trait a canonical
    identity independent of its source name, so diagnostics, codegen
    mangling, and LSP can reference definitions unambiguously even when
    multiple definitions share a name.

    Currently carried on function symbols, overload entries, traits, and
    impl instances. Future phases will extend it to resolved call-site
    metadata so diagnostics, LSP, and codegen can attach the canonical
    identity they resolved to. *)

(** Function purity. *)
type purity = Pure | Impure

(** Whether a function is a user-defined source function, a compiler
    builtin, or a foreign (C FFI) function. *)
type func_origin = UserDefined | Builtin | Foreign

(** Whether a resource-borrowing operation returns ordinary data, an
    independently-owned resource, or a value whose lifetime remains tied to the
    borrowed resource. *)
type resource_result_policy =
  | ResourceResultDependent
  | ResourceResultIndependent
  | ResourceResultOrdinary

(** Whether a function may receive scoped resource values directly.
    Ordinary source functions reject resource arguments because parameters copy
    values. Compiler-owned operations must explicitly opt into borrowing
    resource capabilities for the duration of the call and state whether their
    result remains resource-dependent. *)
type resource_arg_policy =
  | RejectResourceArgs
  | AllowResourceArgs of resource_result_policy

(** Compiler-known loop producer identity. This is declaration metadata, not a
    source-visible type: later phases use it to distinguish genuine loop-view
    producers from unrelated local functions with the same spelling. *)
type loop_producer =
  | LoopProducerIndices
  | LoopProducerEnumerate
  | LoopProducerEnumerate2
  | LoopProducerWindows

type trait_ref = Generic_params.trait_ref = { tr_name : string }
(** Reference to a trait in a bound or obligation. *)

type bound_type_param = Generic_params.bound_type_param = {
  param_name : string;
  param_bounds : trait_ref list;
}
(** Type parameter with optional trait bounds. *)

type overload_entry = {
  ol_def_id : def_id;
  ol_func_type : type_expr;
  ol_type_params : bound_type_param list;
  ol_param_names : string option list;
  ol_purity : purity;
  ol_origin : func_origin;
  ol_resource_args : resource_arg_policy;
  ol_module_path : string option;  (** Which module this overload came from *)
  ol_dim_constraints : (type_expr * type_expr) list;
  ol_loop_producer : loop_producer option;
  ol_debug_only : bool;
}
(** An overload entry records one signature for an overloaded function
    name. Multiple entries per name are allowed (e.g., [get] from
    [std/list] vs [std/dict]).

    [ol_def_id] is minted at registration time by
    [Session.mint_def_id] and gives this specific signature a
    canonical identity independent of its source name. Consumers that
    need to disambiguate "which [get]" (diagnostics, LSP, codegen
    mangling in future phases) key on [ol_def_id] rather than
    reconstructing identity from [ol_module_path] + signature. *)

type impl_instance = {
  ii_def_id : def_id;
  ii_trait : string;
  ii_for_type : type_expr;
  ii_bounds : bound_type_param list;
  ii_is_builtin : bool;
  ii_loc : loc option;
}
(** Impl instance - records that a type implements a trait.

    [ii_is_builtin] distinguishes typecheck-only registrations made by
    [env_builtins] (which don't emit C) from source-level impls. The
    coherence check only rejects conflicts where both the candidate and
    the prior impl are source-level — those are the pairs that would
    collide at link time.

    [ii_loc] is the source location of the impl declaration when known;
    [None] for [env_builtins] impls. Used by the coherence diagnostic
    to cite the previously-registered impl.

    [ii_def_id] is the canonical identity for this impl, minted by
    [Session.mint_def_id]. Lets diagnostics and future codegen refer
    to a specific (trait, type) binding unambiguously. Builtin impls
    also receive def_ids — they're foundational but not special-cased
    at the id level. *)
