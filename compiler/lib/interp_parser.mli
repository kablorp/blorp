(** Interpolated String Parser

    Parses the raw content of interpolated strings into structured parts.
    Must be called after the main parser but before type checking. *)

exception InterpParseError of string * Ast.loc
(** Parse error with message and location. *)

val transform_program : Ast.program -> Ast.program
(** Transform all interpolated strings in a program.
    Replaces raw interpolated string content with parsed
    [EStringInterp] expressions containing sub-expressions. *)
