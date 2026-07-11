(** Dependency-light proof metadata shared by AST typed payloads and
    refinement/inference.

    This module deliberately does not depend on [Ast], [Types], or inference
    state. It is the durable data model for proof facts that can cross the
    typed-expression boundary. *)

type collection_identity
type dimension_identity

type proven_collection = private
  | CollVar of collection_identity
  | CollSubscript of proven_collection * collection_identity
  | CollDim of int

type range_upper = private
  | RangeUpperLit of int
  | RangeUpperDimension of dimension_identity
  | RangeUpperLengthMinus of { coll : collection_identity; end_offset : int }
  | RangeUpperAtMostLength of { coll : collection_identity }

type proof_source =
  | ProofSourceUnknown
  | ProofSourceLoopRange
  | ProofSourceLoopIndices
  | ProofSourceLoopEnumerate
  | ProofSourceCondition
  | ProofSourceRangeTypeFallback

type range_proof = private {
  range_start : int;
  range_upper : range_upper;
  range_source : proof_source;
}

type subscript_proof

type subscript_bound = private
  | ConstantDim of int
  | DimensionBound of dimension_identity
  | CollectionLength of collection_identity

type subscript_bounds = private {
  constant_dims : int list;
  dimension_bounds : dimension_identity list;
  collection_lengths : collection_identity list;
}

type offset_rejection = private
  | OffsetNoMatchingBound
  | OffsetOutOfBounds of string

type offset_subscript_proof = private
  | OffsetProven
  | OffsetRejected of offset_rejection

type value_proofs
type binding_refinement = value_proofs
type expr_proofs = value_proofs

val no_proofs : value_proofs
val unrefined_binding : binding_refinement
val unproven_expr : expr_proofs
val expr_proofs_of_binding : binding_refinement -> expr_proofs
val binding_refinement_of_expr_proofs : expr_proofs -> binding_refinement

val collection_identity_equal :
  collection_identity -> collection_identity -> bool

val dimension_identity_equal : dimension_identity -> dimension_identity -> bool
val proven_collection_equal : proven_collection -> proven_collection -> bool
val collection_identity : string -> collection_identity option
val collection_identity_name : collection_identity -> string
val dimension_identity : string -> dimension_identity option
val collection_var : collection_identity -> proven_collection

val collection_subscript :
  proven_collection -> index:collection_identity -> proven_collection

val collection_dim : int -> proven_collection option
val direct_collection_var : proven_collection -> collection_identity option
val collection_dim_at_most : proven_collection -> size:int -> bool
val range_upper_lit : int -> range_upper option
val range_upper_dimension : dimension_identity -> range_upper

val range_upper_length_minus :
  coll:collection_identity -> end_offset:int -> range_upper option

val range_upper_at_most_length : coll:collection_identity -> range_upper

val make_range_proof_with_source :
  source:proof_source ->
  range_start:int ->
  range_upper:range_upper ->
  range_proof option

val make_subscript_proof :
  source:proof_source -> collection:proven_collection -> subscript_proof

val subscript_proof_collection : subscript_proof -> proven_collection
val subscript_proof_source : subscript_proof -> proof_source
val range_binding : range_proof -> binding_refinement

val binding_add_range_proof :
  binding_refinement -> range_proof -> binding_refinement

val binding_add_subscript_proof :
  ?source:proof_source ->
  binding_refinement ->
  collection:proven_collection ->
  binding_refinement

val binding_range_proof : binding_refinement -> range_proof option

val binding_proves_subscript :
  binding_refinement -> collection:proven_collection -> bool

val binding_proves_dim_at_most : binding_refinement -> size:int -> bool

val binding_direct_collection_vars :
  binding_refinement -> collection_identity list

val binding_proves_direct_range :
  binding_refinement -> bounds:subscript_bound list -> bool

val binding_proves_offset_range :
  binding_refinement ->
  bounds:subscript_bound list ->
  offset:int ->
  offset_subscript_proof

val constant_dim_bound : int -> subscript_bound option
val dimension_bound : dimension_identity -> subscript_bound
val collection_length_bound : collection_identity -> subscript_bound
val subscript_bounds : subscript_bound list -> subscript_bounds
val covers_const_dim : range_proof -> dim:int -> bool
val covers_same_collection : range_proof -> coll:collection_identity -> bool

val covers_const_dim_with_offset :
  range_proof -> dim:int -> offset:int -> (unit, string) result

val covers_same_collection_with_offset :
  range_proof -> coll:collection_identity -> offset:int -> bool

val proves_direct_subscript_with_bounds :
  range_proof -> bounds:subscript_bounds -> bool

val proves_direct_subscript : range_proof -> bounds:subscript_bound list -> bool

val proves_offset_subscript_with_bounds :
  range_proof -> bounds:subscript_bounds -> offset:int -> offset_subscript_proof

val proves_offset_subscript :
  range_proof ->
  bounds:subscript_bound list ->
  offset:int ->
  offset_subscript_proof

val offset_no_matching_bound : offset_subscript_proof
