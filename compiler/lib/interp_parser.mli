(** Interpolated String Parser

    Parses the raw content of interpolated strings into structured parts.
    Must be called after the main parser but before type checking. *)

exception InterpParseError of string * Ast.loc
(** Parse error with message and location. *)

type expr_parse_request = { text : string; loc : Ast.loc }
(** Expression text extracted from one interpolation hole and the location of
    the containing string interpolation expression. *)

val transform_program_with_expr_batch_parser :
  (expr_parse_request list -> Ast.expr list) -> Ast.program -> Ast.program
(** Transform all interpolated strings in a program using one batch parser call
    for all expression text found in the program. *)

val transform_program_with_expr_parser :
  (string -> Ast.loc -> Ast.expr) -> Ast.program -> Ast.program
(** Transform all interpolated strings in a program using the supplied parser
    for expression text inside interpolation holes. *)

val transform_program_with_bootstrap_menhir_expr_parser :
  Ast.program -> Ast.program
(** Transform all interpolated strings in a program through the legacy Menhir
    expression parser. This exists only for the private parser-bridge bootstrap
    path and low-level legacy parser fixtures. Normal source parsing must inject
    the Blorp parser bridge with [transform_program_with_expr_batch_parser]. *)
