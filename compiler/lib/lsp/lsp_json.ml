(** Minimal JSON parser/emitter — no external dependencies.

    Provides just enough JSON support for the LSP server:
    recursive descent parser, pretty-printer, and field accessors. *)

type json =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | Array of json list
  | Object of (string * json) list

(* ============================================================================
   JSON Emitter
   ============================================================================ *)

let escape_string s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let rec to_string = function
  | Null -> "null"
  | Bool true -> "true"
  | Bool false -> "false"
  | Int n -> string_of_int n
  | Float f -> Printf.sprintf "%.17g" f
  | String s -> Printf.sprintf "\"%s\"" (escape_string s)
  | Array items ->
      let parts = List.map to_string items in
      "[" ^ String.concat "," parts ^ "]"
  | Object fields ->
      let parts =
        List.map
          (fun (k, v) ->
            Printf.sprintf "\"%s\":%s" (escape_string k) (to_string v))
          fields
      in
      "{" ^ String.concat "," parts ^ "}"

(* ============================================================================
   JSON Parser — recursive descent over string with index ref
   ============================================================================ *)

exception Parse_error of string

type parser_state = { src : string; mutable pos : int }

let make_parser src = { src; pos = 0 }
let is_whitespace = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false
let is_digit c = c >= '0' && c <= '9'

let is_hex_digit c =
  is_digit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

let at_end p = p.pos >= String.length p.src
let peek p = if at_end p then '\000' else p.src.[p.pos]
let advance p = p.pos <- p.pos + 1

let consume p =
  let c = peek p in
  advance p;
  c

let skip_ws p =
  while (not (at_end p)) && is_whitespace p.src.[p.pos] do
    advance p
  done

let expect p c =
  skip_ws p;
  if peek p <> c then
    raise (Parse_error (Printf.sprintf "expected '%c' at position %d" c p.pos));
  advance p

let parse_error p msg =
  raise (Parse_error (Printf.sprintf "%s at position %d" msg p.pos))

(** Parse a 4-digit hex escape *)
let parse_hex4 p =
  let hex = Buffer.create 4 in
  for _ = 1 to 4 do
    let c = consume p in
    if is_hex_digit c then Buffer.add_char hex c
    else parse_error p "invalid hex digit in \\u escape"
  done;
  int_of_string ("0x" ^ Buffer.contents hex)

(** Encode a Unicode codepoint as UTF-8 *)
let encode_utf8 buf codepoint =
  if codepoint < 0x80 then Buffer.add_char buf (Char.chr codepoint)
  else if codepoint < 0x800 then begin
    Buffer.add_char buf (Char.chr (0xC0 lor (codepoint lsr 6)));
    Buffer.add_char buf (Char.chr (0x80 lor (codepoint land 0x3F)))
  end
  else if codepoint < 0x10000 then begin
    Buffer.add_char buf (Char.chr (0xE0 lor (codepoint lsr 12)));
    Buffer.add_char buf (Char.chr (0x80 lor ((codepoint lsr 6) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor (codepoint land 0x3F)))
  end
  else begin
    Buffer.add_char buf (Char.chr (0xF0 lor (codepoint lsr 18)));
    Buffer.add_char buf (Char.chr (0x80 lor ((codepoint lsr 12) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor ((codepoint lsr 6) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor (codepoint land 0x3F)))
  end

let parse_string p =
  expect p '"';
  let buf = Buffer.create 64 in
  let rec loop () =
    match consume p with
    | '"' -> Buffer.contents buf
    | '\\' -> (
        match consume p with
        | '"' ->
            Buffer.add_char buf '"';
            loop ()
        | '\\' ->
            Buffer.add_char buf '\\';
            loop ()
        | '/' ->
            Buffer.add_char buf '/';
            loop ()
        | 'n' ->
            Buffer.add_char buf '\n';
            loop ()
        | 'r' ->
            Buffer.add_char buf '\r';
            loop ()
        | 't' ->
            Buffer.add_char buf '\t';
            loop ()
        | 'b' ->
            Buffer.add_char buf '\b';
            loop ()
        | 'f' ->
            Buffer.add_char buf (Char.chr 0x0C);
            loop ()
        | 'u' ->
            let hi = parse_hex4 p in
            (* Handle surrogate pairs for codepoints > U+FFFF *)
            if hi >= 0xD800 && hi <= 0xDBFF then begin
              (* High surrogate — expect \uXXXX low surrogate *)
              if consume p <> '\\' || consume p <> 'u' then
                parse_error p "expected low surrogate after high surrogate";
              let lo = parse_hex4 p in
              if lo < 0xDC00 || lo > 0xDFFF then
                parse_error p "invalid low surrogate";
              let codepoint =
                0x10000 + ((hi - 0xD800) * 0x400) + (lo - 0xDC00)
              in
              encode_utf8 buf codepoint
            end
            else encode_utf8 buf hi;
            loop ()
        | c -> parse_error p (Printf.sprintf "invalid escape '\\%c'" c))
    | '\000' -> parse_error p "unterminated string"
    | c when Char.code c < 0x20 ->
        parse_error p "unescaped control character in string"
    | c ->
        Buffer.add_char buf c;
        loop ()
  in
  loop ()

let parse_number p =
  let start = p.pos in
  (* optional minus *)
  if peek p = '-' then advance p;
  (* integer part *)
  if peek p = '0' then advance p
  else if peek p >= '1' && peek p <= '9' then begin
    advance p;
    while is_digit (peek p) do
      advance p
    done
  end
  else parse_error p "expected digit";
  (* fractional part *)
  let is_float = ref false in
  if peek p = '.' then begin
    is_float := true;
    advance p;
    if not (is_digit (peek p)) then
      parse_error p "expected digit after decimal point";
    while is_digit (peek p) do
      advance p
    done
  end;
  (* exponent *)
  if peek p = 'e' || peek p = 'E' then begin
    is_float := true;
    advance p;
    if peek p = '+' || peek p = '-' then advance p;
    if not (is_digit (peek p)) then parse_error p "expected digit in exponent";
    while is_digit (peek p) do
      advance p
    done
  end;
  let s = String.sub p.src start (p.pos - start) in
  if !is_float then Float (float_of_string s) else Int (int_of_string s)

let parse_literal p expected result =
  let len = String.length expected in
  if p.pos + len > String.length p.src then
    parse_error p ("expected " ^ expected);
  for i = 0 to len - 1 do
    if p.src.[p.pos + i] <> expected.[i] then
      parse_error p ("expected " ^ expected)
  done;
  p.pos <- p.pos + len;
  result

let rec parse_value p =
  skip_ws p;
  match peek p with
  | '"' -> String (parse_string p)
  | '{' -> parse_object p
  | '[' -> parse_array p
  | 't' -> parse_literal p "true" (Bool true)
  | 'f' -> parse_literal p "false" (Bool false)
  | 'n' -> parse_literal p "null" Null
  | c when c = '-' || (c >= '0' && c <= '9') -> parse_number p
  | c -> parse_error p (Printf.sprintf "unexpected character '%c'" c)

and parse_object p =
  expect p '{';
  skip_ws p;
  if peek p = '}' then begin
    advance p;
    Object []
  end
  else
    let rec loop acc =
      skip_ws p;
      let key = parse_string p in
      skip_ws p;
      expect p ':';
      let value = parse_value p in
      let acc = (key, value) :: acc in
      skip_ws p;
      match peek p with
      | ',' ->
          advance p;
          loop acc
      | '}' ->
          advance p;
          Object (List.rev acc)
      | _ -> parse_error p "expected ',' or '}' in object"
    in
    loop []

and parse_array p =
  expect p '[';
  skip_ws p;
  if peek p = ']' then begin
    advance p;
    Array []
  end
  else
    let rec loop acc =
      let v = parse_value p in
      let acc = v :: acc in
      skip_ws p;
      match peek p with
      | ',' ->
          advance p;
          loop acc
      | ']' ->
          advance p;
          Array (List.rev acc)
      | _ -> parse_error p "expected ',' or ']' in array"
    in
    loop []

(** Parse a JSON string. Raises Parse_error on invalid input. *)
let parse src =
  let p = make_parser src in
  let v = parse_value p in
  skip_ws p;
  if not (at_end p) then parse_error p "unexpected trailing input";
  v

(* ============================================================================
   Accessors
   ============================================================================ *)

let get key = function Object fields -> List.assoc_opt key fields | _ -> None

let get_string key j =
  match get key j with Some (String s) -> Some s | _ -> None

let get_int key j = match get key j with Some (Int n) -> Some n | _ -> None
let get_list key j = match get key j with Some (Array l) -> Some l | _ -> None
