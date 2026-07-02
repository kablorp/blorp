(** Parsed source comments carried by parser bridge artifacts.

    Comments are explicit parse output data. They are not stored in process-global
    lexer state; callers that need comments should keep the parser artifact or
    pass the comment list directly. *)

type collected_comment = {
  cc_text : string;
  cc_line : int;
  cc_col : int;
  cc_trailing : bool;
      (** True when source code preceded the comment on the same line. *)
}
