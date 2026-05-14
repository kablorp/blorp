(** Tensor producer storage contracts for late Core preparation.

    Producer identities and rules are abstract so only this module can declare
    which runtime calls have storage provenance. Consumers classify a
    [Core.call_kind] first, then handle the known valid cases through
    [fold_storage_rule]; they cannot manufacture or deconstruct producer
    contracts directly. *)

type producer
type storage_rule

val fold_storage_rule :
  known_result:(unit -> 'a) -> preserves_arg:(int -> 'a) -> storage_rule -> 'a

val of_call_kind : Core.call_kind -> producer option
val storage_rule : producer -> storage_rule
val producer_debug_name : producer -> string
