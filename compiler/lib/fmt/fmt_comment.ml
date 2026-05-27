(** Comment store for the Blorp formatter.

    Provides cursor-based access to collected comments, allowing the printer
    to attach comments to AST nodes based on source positions. *)

open Lexer

type t = { mutable remaining : collected_comment list }
(** Mutable comment cursor *)

(** Create a comment store from collected comments *)
let create comments = { remaining = comments }

(** Preserve comment text exactly as the lexer collected it.

    The formatter may move comments to their canonical indentation/line
    position, but comment prose is user-authored text. *)
let comment_text text = text

let consume_prefix t predicate =
  let rec collect acc = function
    | c :: rest when predicate c -> collect (c :: acc) rest
    | remaining ->
        t.remaining <- remaining;
        List.rev acc
  in
  collect [] t.remaining

let pop_head_if t predicate =
  match t.remaining with
  | c :: rest when predicate c ->
      t.remaining <- rest;
      Some c
  | _ -> None

let comment_before_line line comment = comment.cc_line < line

let trailing_on_line line comment =
  comment.cc_line = line && comment.cc_trailing

let trailing_before_line line comment =
  comment.cc_trailing && comment.cc_line < line

(** Take all leading comments with line < before_line.
    Trailing comments whose line < before_line are also collected — they are
    orphans that were never consumed by [take_trailing] (e.g. comments on
    import lines that the formatter reorganises). *)
let take_leading t ~before_line =
  consume_prefix t (comment_before_line before_line)

(** Take a trailing comment on the given line (if any) *)
let take_trailing t ~on_line = pop_head_if t (trailing_on_line on_line)

(** Take the next trailing comment if it appears before the next item line.
    This is used for block expression items whose parser location may point at
    the enclosing form rather than the physical expression line. *)
let take_trailing_before t ~before_line =
  pop_head_if t (trailing_before_line before_line)

(** Take the next trailing comment regardless of line. Used at the end of a
    scoped block after all child expressions have been rendered. *)
let take_next_trailing t = pop_head_if t (fun c -> c.cc_trailing)
