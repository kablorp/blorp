(** Blorp code formatter — public API.

    Fully opinionated, zero-configuration formatter for .brp source files. *)

val format_string : string -> (string, string) result
(** Format a source string through the Blorp renderer. Returns the formatted
    source. *)

val format_program_with_comments :
  comments:Lexer.collected_comment list ->
  Ast.program ->
  (string, string) result
(** Format an already-mutated AST through the Blorp renderer using comments
    collected from the original source. *)

val format_expr_cases_json_lines_string : string -> (string, string) result
(** Parse a source string and return expression-formatting parity cases as
    newline-delimited JSON.

    This is an internal dogfooding boundary for the Blorp expression formatter
    port. *)

val format_decl_cases_json_lines_string : string -> (string, string) result
(** Parse a source string and return declaration-formatting parity cases as
    newline-delimited JSON.

    This is an internal dogfooding boundary for the Blorp declaration formatter
    port. *)

val format_program_json_string : string -> (string, string) result
(** Parse a source string and return full-program formatter JSON.

    This is an internal dogfooding boundary for the Blorp formatter renderer:
    OCaml still owns parsing and comment collection, while Blorp consumes this
    representation and renders formatted source. *)

val format_program_json_file : string -> (string, string) result
(** Parse a source file and return full-program formatter JSON. *)

(** Result for one file formatted through the Blorp renderer. *)
type format_result =
  | Unchanged of string
  | WouldChange of { file : string; diff : string option }
  | Written of string

(** File formatting mode. [Check] reports changed files without writing them;
    [show_diff] includes the formatter diff in changed results. *)
type format_mode = Write | Check of { show_diff : bool }

val format_files_with_blorp_renderer :
  mode:format_mode -> string list -> (format_result list, string) result
(** Format files with OCaml parsing/comment collection and the Blorp
    full-program renderer. *)

val auto_format : string -> unit
(** Auto-format a file in place, silently skipping on any error.
    Uses the format cache to avoid re-formatting unchanged files. *)
