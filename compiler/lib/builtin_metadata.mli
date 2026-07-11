(** Explicit metadata for builtins whose compiler behavior cannot be inferred
    from their source signature alone. *)

type builtin_effect =
  | Impure
  | Parallel_boundary
  | Cancellation_point
      (** Cooperative boundary where a task can observe cancellation. Most are
          fiber park points; [yield_now] is included because it can also unwind
          a cancelled task without being owned by a wait structure. *)
  | Fiber_parking
      (** Operation that may park the current fiber and release the scheduler
          OS worker until readiness, timeout, seal, close, or cancellation
          wakes the exact wait operation. *)
  | Os_worker_blocking
      (** Operation that blocks a scheduler OS worker instead of parking the
          current fiber. This is intentionally distinct from
          [Cancellation_point] until the runtime owns a cancellation-aware
          worker handoff. *)

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
val has_effect : string -> builtin_effect -> bool
val is_impure : string -> bool
val is_parallel_boundary : string -> bool
val special_inference : string -> special_inference option
