(** Resource-sensitive value capability facts.

    This is deliberately separate from ordinary type identity: the same source
    type can be accepted or rejected differently depending on whether it carries
    one-shot cursor/source state directly, inside an ordinary carrier, or behind
    a function endpoint. *)

type target = OneShotStream | ResourceSource
type placement = Direct | OrdinaryCarrier | FunctionCarrier
type item = { target : target; placement : placement }
type t = Ordinary | Carries of item list

val of_items : item list -> t
val has_function_carrier : target -> t -> bool
val is_direct : target -> t -> bool
val has_ordinary_carrier : target -> t -> bool
