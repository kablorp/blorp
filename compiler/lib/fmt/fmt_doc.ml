(** Document IR for the Blorp formatter.

    Wadler-Lindig style document algebra.
    All formatting rules are expressed as compositions of these primitives. *)

(** The document type *)
type doc =
  | Nil  (** Empty document *)
  | Text of string  (** Literal text *)
  | Hardline  (** Unconditional newline + indent *)
  | Softline  (** Newline if broken, nothing if flat *)
  | SoftlineSpace  (** Newline if broken, space if flat *)
  | Indent of int * doc  (** Increase indent by n for sub-doc *)
  | Group of doc  (** Try flat first; if > line_width, break *)
  | Concat of doc * doc  (** Concatenation *)
  | IfBreak of doc * doc  (** (broken_doc, flat_doc) *)
  | LineSuffix of string  (** Trailing comment attached to end of line *)

(** Target line width *)
let line_width = 100

(** Concatenate two documents *)
let ( ^^ ) a b = match (a, b) with Nil, x | x, Nil -> x | _ -> Concat (a, b)

(** Concatenate a list of documents *)
let concat docs = List.fold_left ( ^^ ) Nil docs

(** Text node *)
let text s = if s = "" then Nil else Text s

(** Indented sub-document (4-space default) *)
let indent doc = Indent (4, doc)

(** Group - try flat, break if too wide *)
let group doc = Group doc

(** Hard line break *)
let hardline = Hardline

(** Soft line break - nothing if flat, newline if broken *)
let softline = Softline

(** Soft line break - space if flat, newline if broken *)
let softline_space = SoftlineSpace

(** Trailing comment *)
let line_suffix s = LineSuffix s

(** Separate documents with a separator *)
let intersperse sep docs =
  let rec go = function
    | [] -> Nil
    | [ x ] -> x
    | x :: rest -> x ^^ sep ^^ go rest
  in
  go docs

(** Join with commas and spaces *)
let comma_sep docs = intersperse (text ", ") docs

(** Join with commas, breaking to new lines when needed.
    Adds trailing comma after the last element when the group breaks. *)
let comma_sep_break docs =
  match docs with
  | [] -> Nil
  | [ x ] -> x ^^ IfBreak (text ",", Nil)
  | _ ->
      let rec go = function
        | [] -> Nil
        | [ x ] -> x ^^ IfBreak (text ",", Nil)
        | x :: rest -> x ^^ text "," ^^ softline_space ^^ go rest
      in
      go docs

(** Join with hard line breaks *)
let hardlines docs = intersperse hardline docs

(** Join with n hard line breaks *)
let blank_lines n docs =
  let sep = concat (List.init (n + 1) (fun _ -> hardline)) in
  intersperse sep docs

(** Surround a doc with prefix and suffix *)
let surround l r doc = text l ^^ doc ^^ text r

(** Parenthesized *)
let parens doc = surround "(" ")" doc
