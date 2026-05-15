(** Explicit metadata for builtins whose compiler behavior cannot be inferred
    from their source signature alone. *)

type wait_effect = No_wait | May_park_fiber | May_block_thread
type cancellation_effect = Not_cancellation_point | Cancellation_point

type impure_call_effect = {
  wait : wait_effect;
  cancellation : cancellation_effect;
}

type call_effect = Pure | Impure of impure_call_effect
type builtin_effect = Impure_call | Parallel_boundary

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
val call_effect : string -> call_effect option
val has_effect : string -> builtin_effect -> bool
val is_impure : string -> bool
val is_parallel_boundary : string -> bool
val special_inference : string -> special_inference option
