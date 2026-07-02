(** Parsed source comments collected for formatter-compatible frontend artifacts.

    The legacy OCaml lexer and the Blorp parser bridge both produce this
    shape. Keeping it outside [Lexer] prevents bridge artifacts from depending
    on the OCaml lexer module while that lexer is being retired. *)

type collected_comment = {
  cc_text : string;
  cc_line : int;
  cc_col : int;
  cc_trailing : bool;
      (** True when source code preceded the comment on the same line. *)
}

val reset : unit -> unit
val get : unit -> collected_comment list
val restore : collected_comment list -> unit
val add : collected_comment -> unit
