(** JSON serialization for the formatter document IR.

    This is the OCaml side of the temporary formatter dogfooding boundary:
    OCaml can keep parsing and printing ASTs to [Fmt_doc.doc], while the Blorp
    layout tool can decode this representation and render the final text. *)

module Doc = Fmt_doc
open Doc

let add_unicode_escape b code =
  if code <= 0xffff then Buffer.add_string b (Printf.sprintf "\\u%04x" code)
  else
    let shifted = code - 0x10000 in
    let high = 0xd800 + (shifted lsr 10) in
    let low = 0xdc00 + (shifted land 0x3ff) in
    Buffer.add_string b (Printf.sprintf "\\u%04x\\u%04x" high low)

let is_continuation byte = byte land 0xc0 = 0x80

let decode_utf8_at s i =
  let len = String.length s in
  let byte offset = Char.code s.[i + offset] in
  let b0 = byte 0 in
  if b0 < 0x80 then Some (b0, 1)
  else if b0 land 0xe0 = 0xc0 && i + 1 < len && is_continuation (byte 1) then
    let code = ((b0 land 0x1f) lsl 6) lor (byte 1 land 0x3f) in
    Some (code, 2)
  else if
    b0 land 0xf0 = 0xe0
    && i + 2 < len
    && is_continuation (byte 1)
    && is_continuation (byte 2)
  then
    let code =
      ((b0 land 0x0f) lsl 12)
      lor ((byte 1 land 0x3f) lsl 6)
      lor (byte 2 land 0x3f)
    in
    Some (code, 3)
  else if
    b0 land 0xf8 = 0xf0
    && i + 3 < len
    && is_continuation (byte 1)
    && is_continuation (byte 2)
    && is_continuation (byte 3)
  then
    let code =
      ((b0 land 0x07) lsl 18)
      lor ((byte 1 land 0x3f) lsl 12)
      lor ((byte 2 land 0x3f) lsl 6)
      lor (byte 3 land 0x3f)
    in
    Some (code, 4)
  else None

let escape_string s =
  let b = Buffer.create (String.length s + 8) in
  let rec loop i =
    if i >= String.length s then ()
    else
      match s.[i] with
      | '"' ->
          Buffer.add_string b "\\\"";
          loop (i + 1)
      | '\\' ->
          Buffer.add_string b "\\\\";
          loop (i + 1)
      | '\b' ->
          Buffer.add_string b "\\b";
          loop (i + 1)
      | '\012' ->
          Buffer.add_string b "\\f";
          loop (i + 1)
      | '\n' ->
          Buffer.add_string b "\\n";
          loop (i + 1)
      | '\r' ->
          Buffer.add_string b "\\r";
          loop (i + 1)
      | '\t' ->
          Buffer.add_string b "\\t";
          loop (i + 1)
      | c -> (
          let code = Char.code c in
          if code < 0x20 then (
            add_unicode_escape b code;
            loop (i + 1))
          else if code < 0x80 then (
            Buffer.add_char b c;
            loop (i + 1))
          else
            match decode_utf8_at s i with
            | Some (decoded, width) ->
                add_unicode_escape b decoded;
                loop (i + width)
            | None ->
                add_unicode_escape b code;
                loop (i + 1))
  in
  loop 0;
  Buffer.contents b

let string s = Printf.sprintf "\"%s\"" (escape_string s)
let tag name = Printf.sprintf {|{"tag":%s}|} (string name)

let tag_text name text =
  Printf.sprintf {|{"tag":%s,"text":%s}|} (string name) (string text)

let rec to_json = function
  | Nil -> tag "Nil"
  | Text s -> tag_text "Text" s
  | Hardline -> tag "Hardline"
  | Softline -> tag "Softline"
  | SoftlineSpace -> tag "SoftlineSpace"
  | Indent (width, doc) ->
      Printf.sprintf {|{"tag":%s,"width":%d,"doc":%s}|} (string "Indent") width
        (to_json doc)
  | Group doc ->
      Printf.sprintf {|{"tag":%s,"doc":%s}|} (string "Group") (to_json doc)
  | Concat (left, right) ->
      Printf.sprintf {|{"tag":%s,"left":%s,"right":%s}|} (string "Concat")
        (to_json left) (to_json right)
  | IfBreak (broken_doc, flat_doc) ->
      Printf.sprintf {|{"tag":%s,"broken":%s,"flat":%s}|} (string "IfBreak")
        (to_json broken_doc) (to_json flat_doc)
  | LineSuffix s -> tag_text "LineSuffix" s
