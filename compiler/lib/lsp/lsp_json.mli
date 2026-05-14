(** Minimal JSON parser/emitter — no external dependencies.

    Provides just enough JSON support for the LSP server:
    recursive descent parser, pretty-printer, and field accessors. *)

(** JSON value type *)
type json =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | Array of json list
  | Object of (string * json) list

val to_string : json -> string
(** Convert a JSON value to a compact string representation. *)

exception Parse_error of string
(** Raised on malformed JSON input. *)

val parse : string -> json
(** Parse a JSON string. Raises [Parse_error] on invalid input. *)

val get : string -> json -> json option
(** Look up a key in a JSON object. Returns [None] for non-objects. *)

val get_string : string -> json -> string option
(** Look up a string-valued key. *)

val get_int : string -> json -> int option
(** Look up an integer-valued key. *)

val get_list : string -> json -> json list option
(** Look up an array-valued key. *)
