(** Structured generic parameter and trait-bound helpers. *)

type trait_ref = { tr_name : string }
(** Reference to a trait in a generic bound. *)

type bound_type_param = { param_name : string; param_bounds : trait_ref list }
(** Type parameter with optional trait bounds. *)

val trait_ref : string -> trait_ref
(** Build a trait reference from a parser-level trait name. *)

val trait_ref_name : trait_ref -> string
(** Extract the name from a trait reference. *)

val trait_ref_names : trait_ref list -> string list
(** Extract names from trait references, preserving order. *)

val make_bound_type_param : string -> string list -> bound_type_param
(** Build a structured type parameter bound from parser-level trait names. *)

val to_parser_string : bound_type_param -> string
(** Render a structured bound param using source-level generic-bound spelling. *)

val param_names : bound_type_param list -> string list
(** Extract declared parameter names from structured bound params. *)
