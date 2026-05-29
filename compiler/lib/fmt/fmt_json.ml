(** Small JSON helpers for formatter projections. *)

let add_unicode_escape b code =
  if code <= 0xffff then Buffer.add_string b (Printf.sprintf "\\u%04x" code)
  else
    let shifted = code - 0x10000 in
    let high = 0xd800 + (shifted lsr 10) in
    let low = 0xdc00 + (shifted land 0x3ff) in
    Buffer.add_string b (Printf.sprintf "\\u%04x\\u%04x" high low)

let is_continuation byte = byte land 0xc0 = 0x80
let is_control_code code = code < 0x20
let is_ascii_code code = code < 0x80

let escaped_ascii_char = function
  | '"' -> Some "\\\""
  | '\\' -> Some "\\\\"
  | '\b' -> Some "\\b"
  | '\012' -> Some "\\f"
  | '\n' -> Some "\\n"
  | '\r' -> Some "\\r"
  | '\t' -> Some "\\t"
  | _ -> None

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
      let c = s.[i] in
      match escaped_ascii_char c with
      | Some escaped ->
          Buffer.add_string b escaped;
          loop (i + 1)
      | None -> (
          let code = Char.code s.[i] in
          if is_control_code code then (
            add_unicode_escape b code;
            loop (i + 1))
          else if is_ascii_code code then (
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
