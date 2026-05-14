(** Comment store for the Blorp formatter.

    Provides cursor-based access to collected comments, allowing the printer
    to attach comments to AST nodes based on source positions. *)

open Lexer

type t = { mutable remaining : collected_comment list }
(** Mutable comment cursor *)

(** Create a comment store from collected comments *)
let create comments = { remaining = comments }

(** Normalize comment text: ensure single space after -- *)
let normalize_comment text =
  let len = String.length text in
  if len >= 2 && text.[0] = '-' && text.[1] = '-' then
    let rest = String.sub text 2 (len - 2) in
    let trimmed = String.trim rest in
    if trimmed = "" then "--" else "-- " ^ trimmed
  else text

(** Take all leading comments with line < before_line.
    Trailing comments whose line < before_line are also collected — they are
    orphans that were never consumed by [take_trailing] (e.g. comments on
    import lines that the formatter reorganises). *)
let take_leading t ~before_line =
  let rec collect acc = function
    | c :: rest when c.cc_line < before_line -> collect (c :: acc) rest
    | remaining ->
        t.remaining <- remaining;
        List.rev acc
  in
  collect [] t.remaining

(** Take a trailing comment on the given line (if any) *)
let take_trailing t ~on_line =
  match t.remaining with
  | c :: rest when c.cc_line = on_line && c.cc_trailing ->
      t.remaining <- rest;
      Some c
  | _ -> None

(** Drain all comments (leading and trailing) with line <= through_line.
    Returns them as a list. Used to consume comments in a section that is
    being reformatted (e.g. the import block). *)
let drain_through t ~through_line =
  let rec collect acc = function
    | c :: rest when c.cc_line <= through_line -> collect (c :: acc) rest
    | remaining ->
        t.remaining <- remaining;
        List.rev acc
  in
  collect [] t.remaining

(** Take all remaining comments *)
let take_remaining t =
  let result = t.remaining in
  t.remaining <- [];
  result
