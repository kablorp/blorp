(** Explicit metadata for builtins whose compiler behavior cannot be inferred
    from their source signature alone. *)

type builtin_effect = Impure | Parallel_boundary

type special_inference =
  | Checked_get
  | Checked_set
  | Checked_slice
  | Matrix_checked_get
  | Matrix_checked_set
  | Tensor_checked_get of int
  | Tensor_checked_set of int
  | Assert_shape
  | Length_refined
  | Type_name
  | Is_heap
  | Vector_ctor
  | Matrix_ctor
  | Tensor_ctor of int
  | Bitwise

val duplicate_names : string list
val inert_descriptor_names : string list
val is_registered : string -> bool
val has_effect : string -> builtin_effect -> bool
val is_impure : string -> bool
val is_parallel_boundary : string -> bool
val special_inference : string -> special_inference option
