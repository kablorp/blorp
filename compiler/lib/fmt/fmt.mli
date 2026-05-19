(** Blorp code formatter — public API.

    Fully opinionated, zero-configuration formatter for .brp source files. *)

val format_string : string -> (string, string) result
(** Format a source string. Returns the formatted source. *)

val format_doc_json_string : string -> (string, string) result
(** Parse a source string and return serialized formatter Doc JSON.
    This is an internal dogfooding boundary for the Blorp layout tool. *)

val format_doc_json_file : string -> (string, string) result
(** Parse a source file and return serialized formatter Doc JSON. *)

val format_expr_cases_json_lines_string : string -> (string, string) result
(** Parse a source string and return expression-formatting parity cases as
    newline-delimited JSON.

    This is an internal dogfooding boundary for the Blorp expression formatter
    port. *)

val format_expr_cases_json_lines_file : string -> (string, string) result
(** Parse a source file and return expression-formatting parity JSONL. *)

val format_decl_cases_json_lines_string : string -> (string, string) result
(** Parse a source string and return declaration-formatting parity cases as
    newline-delimited JSON.

    This is an internal dogfooding boundary for the Blorp declaration formatter
    port. *)

val format_decl_cases_json_lines_file : string -> (string, string) result
(** Parse a source file and return declaration-formatting parity JSONL. *)

val format_file :
  ?use_cache:bool -> check:bool -> string -> (bool, string) result
(** Format a file. If [check] is true, returns [Ok true] if the file is
    already formatted, [Ok false] if it would change (without writing).
    If [check] is false, writes the formatted file in place and returns [Ok true].
    Explicit format commands should keep [use_cache] false so parse errors are
    still reported; automatic pre-compile formatting may enable it. *)

val auto_format : string -> unit
(** Auto-format a file in place, silently skipping on any error.
    Uses the format cache to avoid re-formatting unchanged files. *)

val format_check_diff : string -> (string option, string) result
(** Check formatting and return a diff for unformatted files.
    Returns [Ok None] if formatted, [Ok (Some diff)] if not. *)
