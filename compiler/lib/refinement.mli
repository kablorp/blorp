(** Explicit refinement and proof data used by frontend type inference.

    These facts are not runtime layout decisions. They describe why an integer
    expression is safe for a bounded use, such as tensor/vector subscripting.
    Construction is centralized so invalid proofs cannot be introduced by
    directly building records in inference code. *)

include module type of Type_proof_metadata

type proof_env

type branch_subject
type branch_range_proof
type branch_proof_rejection = MutableSubjectCannotNarrow | InvalidRangeBounds

val empty_proof_env : proof_env

val proof_env_without_subscript :
  proof_env -> var:collection_identity -> proof_env

val proof_env_without_range : proof_env -> var:collection_identity -> proof_env

val proof_env_add_subscript :
  ?source:proof_source ->
  proof_env ->
  var:collection_identity ->
  collection:proven_collection ->
  proof_env

val proof_env_apply_subscript_to_binding :
  proof_env ->
  var:collection_identity ->
  binding_refinement ->
  binding_refinement

val proof_env_add_range_bounds :
  ?source:proof_source ->
  proof_env ->
  var:collection_identity ->
  range_start:int ->
  range_upper:range_upper ->
  proof_env

val proof_env_find_range :
  proof_env -> var:collection_identity -> range_proof option

val immutable_subject : string -> branch_subject option

val mutable_subject : string -> branch_subject option

val make_branch_range_proof :
  branch_subject ->
  range_start:int ->
  range_upper:range_upper ->
  (branch_range_proof, branch_proof_rejection) result

val branch_range_proof : branch_range_proof -> range_proof
