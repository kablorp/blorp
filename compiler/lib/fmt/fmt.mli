(** Blorp code formatter — public API.

    Fully opinionated, zero-configuration formatter for .brp source files. *)

val format_string : string -> (string, string) result
(** Format a source string. Returns the formatted source. *)

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
