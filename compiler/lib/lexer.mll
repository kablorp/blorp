{
(** Blorp Lexer with indentation tracking

    This lexer handles:
    - Indentation-sensitive tokenization (INDENT/DEDENT)
    - All blorp keywords and operators

    Key design: NEWLINE is NOT emitted before DEDENT. When a line ends and the
    next line has less indentation, only DEDENT is emitted, not NEWLINE DEDENT.
*)

exception LexError of string * int * int

(** Collected comment for formatter *)
type collected_comment = {
  cc_text: string;
  cc_line: int;
  cc_col: int;
  cc_trailing: bool;  (** Was there code before this on the same line? *)
}

let comment_store : collected_comment list ref = ref []
let reset_comments () = comment_store := []
let get_comments () = List.rev !comment_store
let restore_comments (cs : collected_comment list) = comment_store := List.rev cs

(** Lexer state for indentation tracking *)
type lexer_state = {
  mutable indent_stack: int list;  (** Stack of indent levels *)
  mutable pending_tokens: Parser.token list;  (** Tokens to emit before next lex *)
  mutable at_line_start: bool;  (** Are we at start of line? *)
  mutable has_token_on_line: bool;  (** Has a non-whitespace token been seen on this line? (for comment trailing) *)
  mutable paren_depth: int;  (** Depth of (), [], {} - ignore newlines inside *)
  mutable lambda_body_levels: (int * int) list;  (** Stack of (paren_depth, indent_level) for lambda bodies *)
  mutable line: int;
  mutable col: int;
  mutable pending_newline: bool;  (** Deferred NEWLINE waiting to be emitted *)
  mutable just_dedented: bool;  (** True after DEDENT emitted, cleared on next real token. Suppresses NEWLINE from comment-only lines between if/else. *)
  mutable last_token: Parser.token option;  (** Last token emitted (for lambda detection) *)
  mutable string_start_line: int;  (** Line where current string literal started *)
  mutable string_start_col: int;  (** Column where current string literal started *)
  mutable interp_depth: int;  (** Current string interpolation nesting depth *)
}

let create_state () = {
  indent_stack = [0];
  pending_tokens = [];
  at_line_start = true;
  has_token_on_line = false;
  paren_depth = 0;
  lambda_body_levels = [];
  line = 1;
  col = 1;
  pending_newline = false;
  just_dedented = false;
  last_token = None;
  string_start_line = 1;
  string_start_col = 1;
  interp_depth = 0;
}

let state = create_state ()

let reset_state () =
  state.indent_stack <- [0];
  state.pending_tokens <- [];
  state.at_line_start <- true;
  state.has_token_on_line <- false;
  state.paren_depth <- 0;
  state.lambda_body_levels <- [];
  state.line <- 1;
  state.col <- 1;
  state.pending_newline <- false;
  state.just_dedented <- false;
  state.last_token <- None;
  state.string_start_line <- 1;
  state.string_start_col <- 1;
  state.interp_depth <- 0;
  reset_comments ()

(** Keyword table *)
let keywords = Hashtbl.create 50
let () =
  List.iter (fun (k, v) -> Hashtbl.add keywords k v) [
    ("func", Parser.FUNC);
    ("pure", Parser.PURE);
    ("var", Parser.VAR);
    ("union", Parser.UNION);
    ("enum", Parser.ENUM);
    ("record", Parser.RECORD);
    ("void", Parser.VOID_KW);
    ("while", Parser.WHILE);
    ("for", Parser.FOR);
    ("in", Parser.IN);
    ("if", Parser.IF);
    ("else", Parser.ELSE);
    ("and", Parser.AND);
    ("or", Parser.OR);
    ("not", Parser.NOT);
    ("implements", Parser.IMPLEMENTS);
    ("trait", Parser.TRAIT);
    ("Self", Parser.SELF_TYPE);
    ("type", Parser.TYPE);
    ("alias", Parser.ALIAS);
    ("builtin", Parser.BUILTIN);
    ("import", Parser.IMPORT);
    ("as", Parser.AS);
    ("private", Parser.PRIVATE);
    ("export", Parser.EXPORT);
    ("match", Parser.MATCH);
    ("True", Parser.TRUE);
    ("False", Parser.FALSE);
    ("break", Parser.BREAK);
    ("continue", Parser.CONTINUE);
    ("try", Parser.TRY);
    ("with", Parser.WITH);
    ("resource", Parser.RESOURCE);
    ("debug", Parser.DEBUG);
    ("struct", Parser.STRUCT);
    ("foreign", Parser.FOREIGN);
    ("concurrent", Parser.CONCURRENT);
    ("concurrently", Parser.CONCURRENTLY);
    ("detach", Parser.DETACH);
    ("select", Parser.SELECT);
    ("from", Parser.FROM);
    ("after", Parser.AFTER);
    ("sealed", Parser.SEALED);
    ("where", Parser.WHERE);
  ]

(** Look up identifier, return keyword or IDENT *)
let lookup_ident s =
  try Hashtbl.find keywords s
  with Not_found -> Parser.IDENT s

(** Calculate column width of whitespace (tabs = 4 spaces) *)
let calc_indent s =
  let len = String.length s in
  let rec loop i acc =
    if i >= len then acc
    else match s.[i] with
      | ' ' -> loop (i + 1) (acc + 1)
      | '\t' -> loop (i + 1) (acc + 4 - (acc mod 4))
      | _ -> acc
  in
  loop 0 0

(** Check if we're currently in a lambda body *)
let in_lambda_body () =
  match state.lambda_body_levels with
  | (pd, _) :: _ -> state.paren_depth >= pd
  | [] -> false

(** Check if we're inside nested parens within a lambda body.
    When true, newlines should be suppressed (same as outside lambda bodies)
    because we're inside a function call/list literal within the lambda. *)
let in_nested_parens_in_lambda () =
  match state.lambda_body_levels with
  | (pd, _) :: _ -> state.paren_depth > pd
  | [] -> false

(** Safe accessor for current indent level. Returns 0 if stack is empty. *)
let current_indent () =
  match state.indent_stack with
  | level :: _ -> level
  | [] -> 0

(** Save position where a string literal starts (for error messages) *)
let save_string_start () =
  state.string_start_line <- state.line;
  state.string_start_col <- state.col

(** Handle indentation change at line start. Returns true if DEDENT was emitted. *)
let handle_indent indent =
  (* Pre-check: when in a lambda body inside brackets (e.g., list/tuple literals),
     the closing paren/bracket line may have an indent level not on the indent stack.
     Normal dedent would error with "Inconsistent indentation". Instead, detect this
     and cleanly exit the lambda body by popping its indent levels. *)
  (match state.lambda_body_levels with
   | (_, base_indent) :: rest ->
       let current = current_indent () in
       if indent < current then begin
         (* Check if normal dedent would fail (indent between two stack levels) *)
         let would_be_inconsistent =
           let rec check = function
             | level :: _ when indent >= level -> false
             | _ :: more ->
                 if indent > (match more with h :: _ -> h | [] -> 0) then true
                 else check more
             | [] -> false
           in
           check state.indent_stack
         in
         if would_be_inconsistent then begin
           (* Exit the lambda body: pop all indent levels above base, emit DEDENTs *)
           let rec pop_above base acc = function
             | level :: remaining when level > base ->
                 pop_above base (Parser.DEDENT :: acc) remaining
             | stack -> (stack, acc)
           in
           let (new_stack, dedents) = pop_above base_indent [] state.indent_stack in
           state.indent_stack <- new_stack;
           state.lambda_body_levels <- rest;
           state.pending_newline <- false;
           state.pending_tokens <- dedents
         end
       end
   | [] -> ());
  (* Skip indentation handling when inside parentheses, unless in a lambda body.
     Also skip when inside nested parens within a lambda body (e.g., function calls). *)
  if state.paren_depth > 0 && (not (in_lambda_body ()) || in_nested_parens_in_lambda ()) then begin
    state.pending_newline <- false;  (* Discard pending newline *)
    false
  end else
  let current = current_indent () in
  if indent > current then begin
    (* Increased indentation - emit pending NEWLINE first, then INDENT *)
    state.indent_stack <- indent :: state.indent_stack;
    if state.pending_newline then begin
      state.pending_newline <- false;
      state.pending_tokens <- [Parser.NEWLINE; Parser.INDENT]
    end else
      state.pending_tokens <- [Parser.INDENT];
    false
  end else if indent < current then begin
    (* Decreased indentation - skip pending NEWLINE, emit DEDENTs *)
    state.pending_newline <- false;  (* Don't emit NEWLINE before DEDENT *)
    let rec pop_indents stack tokens =
      match stack with
      | [] -> raise (LexError ("Unexpected dedent: no matching indentation level", state.line, 1))
      | [0] -> ([0], tokens)
      | level :: rest ->
          if indent >= level then (stack, tokens)
          else if indent > (match rest with h :: _ -> h | [] -> 0) then
            let expected = String.concat ", " (List.map string_of_int (List.filter (fun l -> l < current) state.indent_stack)) in
            raise (LexError (Printf.sprintf "Inconsistent indentation: expected one of [%s] spaces, got %d" expected indent, state.line, 1))
          else pop_indents rest (Parser.DEDENT :: tokens)
    in
    let (new_stack, dedents) = pop_indents state.indent_stack [] in
    state.indent_stack <- new_stack;
    state.pending_tokens <- List.rev dedents;
    state.just_dedented <- true;
    true
  end else begin
    (* Same indentation - emit pending NEWLINE if we have one *)
    if state.pending_newline then begin
      state.pending_newline <- false;
      state.pending_tokens <- [Parser.NEWLINE]
    end;
    false
  end

(** Encode a Unicode codepoint as UTF-8 bytes into a Buffer *)
let utf8_encode_to_buffer buf cp =
  if cp < 0x80 then
    Buffer.add_char buf (Char.chr cp)
  else if cp < 0x800 then begin
    Buffer.add_char buf (Char.chr (0xC0 lor (cp lsr 6)));
    Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
  end else if cp < 0x10000 then begin
    Buffer.add_char buf (Char.chr (0xE0 lor (cp lsr 12)));
    Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
  end else begin
    Buffer.add_char buf (Char.chr (0xF0 lor (cp lsr 18)));
    Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
  end

(** Validate and encode a unicode escape hex string into buffer *)
let handle_unicode_escape buf hex_str =
  if String.length hex_str = 0 || String.length hex_str > 6 then
    raise (LexError ("Unicode escape \\u{} must contain 1-6 hex digits", state.line, state.col));
  let cp = int_of_string ("0x" ^ hex_str) in
  if cp > 0x10FFFF then
    raise (LexError (Printf.sprintf "Unicode codepoint U+%X is out of range (max U+10FFFF)" cp, state.line, state.col));
  if cp >= 0xD800 && cp <= 0xDFFF then
    raise (LexError (Printf.sprintf "Unicode codepoint U+%X is a surrogate (U+D800..U+DFFF not allowed)" cp, state.line, state.col));
  utf8_encode_to_buffer buf cp

(** Parse escape sequence in string *)
let parse_escape c =
  match c with
  | 'n' -> '\n'
  | 't' -> '\t'
  | 'r' -> '\r'
  | '\\' -> '\\'
  | '"' -> '"'
  | '\'' -> '\''
  | '0' -> '\000'
  | '{' -> '{'
  | '}' -> '}'
  | _ -> raise (LexError (Printf.sprintf "Unknown escape sequence '\\%c'" c, state.line, state.col))

(** Update position tracking *)
let update_pos lexbuf =
  let s = Lexing.lexeme lexbuf in
  let len = String.length s in
  for i = 0 to len - 1 do
    if s.[i] = '\n' then begin
      state.line <- state.line + 1;
      state.col <- 1;
      Lexing.new_line lexbuf  (* Update Menhir's position tracking *)
    end else if s.[i] = '\t' then
      state.col <- state.col + 4 - ((state.col - 1) mod 4)
    else
      state.col <- state.col + 1
  done

let incr_paren () = state.paren_depth <- state.paren_depth + 1
let decr_paren () = state.paren_depth <- max 0 (state.paren_depth - 1)

(** Parse an integer literal. Values that fit in [int64] stay compact;
    larger decimal literals are preserved as source digits and inferred as
    [Int128]. *)
let int128_max = "170141183460469231731687303715884105727"

let decimal_leq a b =
  let strip s =
    let len = String.length s in
    let rec go i =
      if i + 1 < len && s.[i] = '0' then go (i + 1) else i
    in
    String.sub s (go 0) (len - go 0)
  in
  let a = strip a in
  let b = strip b in
  let la = String.length a in
  let lb = String.length b in
  la < lb || (la = lb && String.compare a b <= 0)

let integer_token s =
  try Int64.of_string s
      |> fun n -> Parser.INT n
  with Failure _ ->
    if decimal_leq s int128_max then Parser.BIGINT s
    else
      raise (LexError (Printf.sprintf "Integer literal '%s' exceeds Int128 range" s, state.line, state.col))

let is_ident_start_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '_' -> true
  | _ -> false

let is_digit_char = function
  | '0' .. '9' -> true
  | _ -> false

let lexbuf_peek lexbuf offset =
  let pos = lexbuf.Lexing.lex_curr_pos + offset in
  if pos < lexbuf.Lexing.lex_buffer_len then
    Some (Bytes.get lexbuf.Lexing.lex_buffer pos)
  else
    None

let starts_dot_continuation lexbuf =
  match lexbuf_peek lexbuf 0, lexbuf_peek lexbuf 1 with
  | Some '.', Some c when is_ident_start_char c || is_digit_char c -> true
  | _ -> false

let starts_pipe_string_continuation lexbuf =
  match lexbuf_peek lexbuf 0 with
  | Some '|' -> true
  | _ -> false

let starts_line_comment lexbuf =
  match lexbuf_peek lexbuf 0, lexbuf_peek lexbuf 1 with
  | Some '-', Some '-' -> true
  | _ -> false

let next_line_starts_with_pipe_margin lexbuf margin_col =
  let rec loop offset indent =
    match lexbuf_peek lexbuf offset with
    | Some ' ' -> loop (offset + 1) (indent + 1)
    | Some '\t' -> loop (offset + 1) (indent + 4 - (indent mod 4))
    | Some '|' -> indent = margin_col - 1
    | _ -> false
  in
  loop 0 0

let starts_raw_pipe_block lexbuf =
  let rec skip_to_next_line offset =
    match lexbuf_peek lexbuf offset with
    | Some (' ' | '\t') -> skip_to_next_line (offset + 1)
    | Some '\n' -> Some (offset + 1)
    | Some '\r' -> (
        match lexbuf_peek lexbuf (offset + 1) with
        | Some '\n' -> Some (offset + 2)
        | _ -> None)
    | _ -> None
  in
  let rec next_token_is_pipe offset =
    match lexbuf_peek lexbuf offset with
    | Some ' ' -> next_token_is_pipe (offset + 1)
    | Some '\t' -> next_token_is_pipe (offset + 1)
    | Some '|' -> true
    | _ -> false
  in
  match skip_to_next_line 0 with
  | Some offset -> next_token_is_pipe offset
  | None -> false

let append_pipe_line_content ~raw buf line =
  if raw then begin
    Buffer.add_string buf line;
    false
  end else
    let len = String.length line in
    let rec loop i saw_interp =
      if i >= len then saw_interp
      else
        match line.[i] with
        | '$' when i + 1 < len && line.[i + 1] = '{' ->
            Buffer.add_char buf '{';
            loop (i + 2) true
        | c ->
            Buffer.add_char buf c;
            loop (i + 1) saw_interp
    in
    loop 0 false

let mark_direct_token tok =
  state.has_token_on_line <- true;
  state.just_dedented <- false;
  tok

let pipe_string_token ~raw content saw_interp =
  mark_direct_token
    (if raw then Parser.PIPE_STRING_RAW content
     else if saw_interp then Parser.PIPE_STRING_INTERP content
     else Parser.PIPE_STRING content)

(** Check for pending tokens, process line start *)
(* Decode a UTF-8 byte sequence into a Unicode codepoint.
   Validates continuation bytes (must be 10xxxxxx) and rejects overlong encodings. *)
let decode_utf8_char s =
  let len = String.length s in
  if len = 0 then failwith "empty char"
  else if len = 1 then Char.code s.[0]
  else
    let b0 = Char.code s.[0] in
    let is_cont b = b land 0xC0 = 0x80 in
    if b0 land 0xE0 = 0xC0 && len = 2 then
      let b1 = Char.code s.[1] in
      if not (is_cont b1) then failwith "invalid UTF-8";
      let cp = ((b0 land 0x1F) lsl 6) lor (b1 land 0x3F) in
      if cp < 0x80 then failwith "overlong UTF-8";
      cp
    else if b0 land 0xF0 = 0xE0 && len = 3 then
      let b1 = Char.code s.[1] in
      let b2 = Char.code s.[2] in
      if not (is_cont b1 && is_cont b2) then failwith "invalid UTF-8";
      let cp = ((b0 land 0x0F) lsl 12) lor ((b1 land 0x3F) lsl 6) lor (b2 land 0x3F) in
      if cp < 0x800 then failwith "overlong UTF-8";
      cp
    else if b0 land 0xF8 = 0xF0 && len = 4 then
      let b1 = Char.code s.[1] in
      let b2 = Char.code s.[2] in
      let b3 = Char.code s.[3] in
      if not (is_cont b1 && is_cont b2 && is_cont b3) then failwith "invalid UTF-8";
      let cp = ((b0 land 0x07) lsl 18) lor ((b1 land 0x3F) lsl 12) lor ((b2 land 0x3F) lsl 6) lor (b3 land 0x3F) in
      if cp < 0x10000 then failwith "overlong UTF-8";
      cp
    else failwith "invalid UTF-8"

let check_line_start () =
  if state.at_line_start then begin
    let _ = handle_indent 0 in
    state.at_line_start <- false
  end

(** Return next token, considering pending tokens and newline *)
let emit_or_pending tok =
  check_line_start ();
  state.has_token_on_line <- true;
  state.just_dedented <- false;
  let result = match state.pending_tokens with
  | pending :: rest ->
      state.pending_tokens <- rest @ [tok];
      pending
  | [] -> tok
  in
  state.last_token <- Some result;
  result

}

let digit = ['0'-'9']
let alpha = ['a'-'z' 'A'-'Z']
let alphanum = alpha | digit | '_'
let ident = (alpha | '_') alphanum*
let integer = digit+
(* Float must have digits on both sides of the decimal point.
   This prevents 0. from being lexed as a float, allowing 0..5 to parse as range. *)
let float_num = digit+ '.' digit+
let whitespace = [' ' '\t']+
let newline = '\n' | '\r' '\n'

rule token = parse
  (* Docstrings --- ... --- *)
  | "---" whitespace? newline {
      update_pos lexbuf;
      state.at_line_start <- true;
      read_docstring (Buffer.create 256) lexbuf
    }

  (* Line comments - collect for formatter and continue *)
  | "--" ([^ '\n']* as ctext) {
      update_pos lexbuf;
      comment_store := {
        cc_text = "--" ^ ctext;
        cc_line = state.line;
        cc_col = state.col - String.length ctext - 2;
        cc_trailing = state.has_token_on_line;
      } :: !comment_store;
      token lexbuf
    }

  (* Newline handling - defer emission *)
  | newline {
      update_pos lexbuf;
      state.at_line_start <- true;
      state.has_token_on_line <- false;
      (* Check if we're entering a lambda body (COLON followed by newline inside parens)
         Only enter a new lambda if paren_depth is greater than the depth of any existing
         lambda we're tracking (this allows nested lambdas while ignoring match arms) *)
      let should_enter_lambda =
        state.paren_depth > 0 &&
        state.last_token = Some Parser.COLON &&
        (match state.lambda_body_levels with
         | [] -> true  (* No lambdas yet, this could be one *)
         | (pd, _) :: _ -> state.paren_depth > pd)  (* Only if deeper paren depth *)
      in
      if should_enter_lambda then begin
        (* Lambda body - record paren depth and current indent level *)
        let cur_indent = current_indent () in
        state.lambda_body_levels <- (state.paren_depth, cur_indent) :: state.lambda_body_levels;
        state.pending_newline <- true;
        token lexbuf
      end else if state.paren_depth > 0 && (not (in_lambda_body ()) || in_nested_parens_in_lambda ()) then
        token lexbuf  (* Ignore newlines inside brackets, unless in lambda body *)
      else begin
        (* After a DEDENT, comment-only lines should not insert NEWLINE.
           This preserves DEDENT-ELSE adjacency for if/else chains with
           comments between branches. *)
        if not (state.just_dedented && not state.has_token_on_line) then
          state.pending_newline <- true;
        token lexbuf  (* Continue to see what's next *)
      end
    }

  (* Whitespace at line start - calculate indent *)
  | whitespace as ws {
      update_pos lexbuf;
      if state.at_line_start then begin
        let indent = calc_indent ws in
        if starts_line_comment lexbuf then
          token lexbuf
        else if state.pending_newline && indent > current_indent () && starts_dot_continuation lexbuf then begin
          state.pending_newline <- false;
          state.at_line_start <- false;
          token lexbuf
        end else if state.pending_newline && starts_pipe_string_continuation lexbuf then begin
          state.pending_newline <- false;
          state.at_line_start <- false;
          token lexbuf
        end else begin
          let _ = handle_indent indent in
          state.at_line_start <- false;
          match state.pending_tokens with
          | tok :: rest ->
              state.pending_tokens <- rest;
              tok
          | [] -> token lexbuf
        end
      end else
        token lexbuf  (* Skip whitespace not at line start *)
    }

  (* Two-character operators *)
  | "->" { update_pos lexbuf; emit_or_pending Parser.ARROW }
  | "=>" { update_pos lexbuf; emit_or_pending Parser.FATARROW }
  | "<=" { update_pos lexbuf; emit_or_pending Parser.LE }
  | ">=" { update_pos lexbuf; emit_or_pending Parser.GE }
  | "==" { update_pos lexbuf; emit_or_pending Parser.EQ }
  | "!=" { update_pos lexbuf; emit_or_pending Parser.NE }
  | "?=" { update_pos lexbuf; emit_or_pending Parser.QUESTION_EQUALS }
  | "??" { update_pos lexbuf; raise (LexError ("?? syntax has been removed. Use #Name... for variadic dimensions (e.g., T[#Ds...])", state.line, state.col)) }

  (* Single-character operators and punctuation *)
  | '(' { update_pos lexbuf; incr_paren (); emit_or_pending Parser.LPAREN }
  | ')' { update_pos lexbuf; decr_paren (); emit_or_pending Parser.RPAREN }
  | '[' { update_pos lexbuf; incr_paren (); emit_or_pending Parser.LBRACKET }
  | ']' { update_pos lexbuf; decr_paren (); emit_or_pending Parser.RBRACKET }
  | '{' { update_pos lexbuf; incr_paren (); emit_or_pending Parser.LBRACE }
  | '}' { update_pos lexbuf; decr_paren (); emit_or_pending Parser.RBRACE }
  | ':' { update_pos lexbuf; emit_or_pending Parser.COLON }
  | ',' { update_pos lexbuf; emit_or_pending Parser.COMMA }
  | "..." { update_pos lexbuf; emit_or_pending Parser.DOTDOTDOT }
  | ".." { update_pos lexbuf; emit_or_pending Parser.DOTDOT }
  | '.' { update_pos lexbuf; emit_or_pending Parser.DOT }
  | "+=" { update_pos lexbuf; emit_or_pending Parser.PLUS_EQ }
  | "-=" { update_pos lexbuf; emit_or_pending Parser.MINUS_EQ }
  | "*=" { update_pos lexbuf; emit_or_pending Parser.STAR_EQ }
  | "/=" { update_pos lexbuf; emit_or_pending Parser.SLASH_EQ }
  | '+' { update_pos lexbuf; emit_or_pending Parser.PLUS }
  | '-' { update_pos lexbuf; emit_or_pending Parser.MINUS }
  | '*' { update_pos lexbuf; emit_or_pending Parser.STAR }
  | '/' { update_pos lexbuf; emit_or_pending Parser.SLASH }
  | '_' { update_pos lexbuf; emit_or_pending Parser.UNDERSCORE }
  | '<' { update_pos lexbuf; emit_or_pending Parser.LT }
  | '>' { update_pos lexbuf; emit_or_pending Parser.GT }
  | '%' { update_pos lexbuf; emit_or_pending Parser.PERCENT }
  | "||" {
      if not state.has_token_on_line then begin
        let margin_col = state.col in
        update_pos lexbuf;
        state.pending_newline <- false;
        state.at_line_start <- false;
        state.has_token_on_line <- true;
        state.just_dedented <- false;
        save_string_start ();
        let buf = Buffer.create 256 in
        Buffer.add_char buf '|';
        read_pipe_line margin_col buf false false true lexbuf
      end else
        raise (LexError ("blorp uses 'or' instead of '||'", state.line, state.col))
    }
  | '|' {
      if not state.has_token_on_line then begin
        let margin_col = state.col in
        update_pos lexbuf;
        state.pending_newline <- false;
        state.at_line_start <- false;
        state.has_token_on_line <- true;
        state.just_dedented <- false;
        save_string_start ();
        read_pipe_line margin_col (Buffer.create 256) false false true lexbuf
      end else begin
        update_pos lexbuf;
        emit_or_pending Parser.PIPE
      end
    }
  | '#' { update_pos lexbuf; emit_or_pending Parser.HASH }
  | '@' { update_pos lexbuf; emit_or_pending Parser.AT }
  | '=' { update_pos lexbuf; emit_or_pending Parser.EQUALS }

  (* Float literal (must come before integer to handle ".") *)
  | float_num as f { update_pos lexbuf; emit_or_pending (Parser.FLOAT (float_of_string f)) }

  (* Integer literal *)
  | integer as n { update_pos lexbuf; emit_or_pending (integer_token n) }

  (* Triple-quoted strings were removed in favor of aligned pipe strings. *)
  | "\"\"\"" {
      update_pos lexbuf;
      raise (LexError ("triple-quoted strings were removed; use aligned pipe strings for multiline text", state.line, state.col))
    }

  (* Raw string literal - raw"..." with no escape processing *)
  | "raw\"" { update_pos lexbuf; check_line_start (); save_string_start (); read_raw_string (Buffer.create 64) lexbuf }

  (* Removed compact raw string literal spelling. *)
  | "r\"" { update_pos lexbuf; raise (LexError ("raw strings use raw\"...\", not r\"...\"", state.line, state.col)) }

  (* String literal *)
  | '"' { update_pos lexbuf; check_line_start (); save_string_start (); read_string (Buffer.create 64) lexbuf }

  (* Character literal *)
  | '\'' { update_pos lexbuf; check_line_start (); read_char lexbuf }

  (* Identifiers and keywords *)
  | ident as id {
      if id = "raw" && starts_raw_pipe_block lexbuf then begin
        update_pos lexbuf;
        state.has_token_on_line <- true;
        state.just_dedented <- false;
        save_string_start ();
        read_raw_pipe_start lexbuf
      end else begin
        update_pos lexbuf;
        emit_or_pending (lookup_ident id)
      end
    }

  (* End of file *)
  | eof {
      check_line_start ();
      state.pending_newline <- false;  (* Don't emit trailing NEWLINE *)
      (* Return pending tokens first *)
      match state.pending_tokens with
      | tok :: rest ->
          state.pending_tokens <- rest;
          tok
      | [] ->
          (* Emit remaining DEDENTs - build list properly *)
          let rec count_dedents stack acc =
            match stack with
            | [] | [0] -> acc
            | _ :: rest -> count_dedents rest (Parser.DEDENT :: acc)
          in
          match state.indent_stack with
          | [] | [0] -> Parser.EOF
          | _ ->
              let dedents = count_dedents state.indent_stack [] in
              state.indent_stack <- [0];
              match dedents with
              | [] -> Parser.EOF
              | d :: rest ->
                  state.pending_tokens <- rest @ [Parser.EOF];
                  d
    }

  (* Common operators from other languages — give helpful hints *)
  | "&&" {
      raise (LexError ("blorp uses 'and' instead of '&&'", state.line, state.col))
    }
  | "||" {
      raise (LexError ("blorp uses 'or' instead of '||'", state.line, state.col))
    }
  | ";" {
      raise (LexError ("blorp doesn't use semicolons — statements are separated by newlines", state.line, state.col))
    }
  | "!" {
      raise (LexError ("blorp uses 'not' instead of '!'", state.line, state.col))
    }
  | "?" {
      raise (LexError ("blorp doesn't use postfix '?'. For error propagation, use `name ?= expr` statements in a function returning Option or Result", state.line, state.col))
    }

  (* Unknown character *)
  | _ as c {
      raise (LexError (Printf.sprintf "Unexpected character '%c'" c, state.line, state.col))
    }

and read_string buf = parse
  | '"' { update_pos lexbuf; mark_direct_token (Parser.STRING (Buffer.contents buf)) }
  | "\\u{" (['0'-'9' 'a'-'f' 'A'-'F']+ as hex) '}' {
      update_pos lexbuf;
      handle_unicode_escape buf hex;
      read_string buf lexbuf
    }
  | '\\' (_ as c) {
      update_pos lexbuf;
      Buffer.add_char buf (parse_escape c);
      read_string buf lexbuf
    }
  | "${" {
      (* Found ${ - this is string interpolation *)
      update_pos lexbuf;
      state.interp_depth <- state.interp_depth + 1;
      if state.interp_depth > 64 then
        raise (LexError ("string interpolation nested too deeply (max 64)", state.line, state.col));
      let prefix = Buffer.contents buf in
      Buffer.clear buf;
      Buffer.add_char buf '{';
      read_interp_string prefix buf 1 false lexbuf
    }
  | [^ '"' '\\' '\n' '$']+ as s {
      update_pos lexbuf;
      Buffer.add_string buf s;
      read_string buf lexbuf
    }
  | '$' {
      (* Lone $ not followed by { — literal $ *)
      update_pos lexbuf;
      Buffer.add_char buf '$';
      read_string buf lexbuf
    }
  | newline {
      raise (LexError (Printf.sprintf "Unterminated string literal (started at line %d, column %d). Use aligned pipe strings for multiline text" state.string_start_line state.string_start_col, state.line, state.col))
    }
  | eof {
      raise (LexError (Printf.sprintf "Unterminated string literal: missing closing '\"' (started at line %d, column %d)" state.string_start_line state.string_start_col, state.line, state.col))
    }

(** Read a raw string literal raw"..." — no escape processing, all characters are literal *)
and read_raw_string buf = parse
  | '"' { update_pos lexbuf; mark_direct_token (Parser.STRING_RAW (Buffer.contents buf)) }
  | [^ '"' '\n']+ as s {
      update_pos lexbuf;
      Buffer.add_string buf s;
      read_raw_string buf lexbuf
    }
  | newline {
      raise (LexError (Printf.sprintf "Raw string cannot span multiple lines (started at line %d, column %d). Use raw followed by an aligned pipe string for raw multiline text" state.string_start_line state.string_start_col, state.line, state.col))
    }
  | eof {
      raise (LexError (Printf.sprintf "Unterminated raw string literal: missing closing '\"' (started at line %d, column %d)" state.string_start_line state.string_start_col, state.line, state.col))
    }

(** Read an interpolated string, collecting raw content including braces.
    prefix: accumulated literal content before the first {
    buf: current accumulator (contains the opening { we just saw)
    brace_depth: current nesting depth of braces
    in_string: whether we're inside a nested string literal within an expression *)
and read_interp_string prefix buf brace_depth in_string = parse
  | '"' {
      update_pos lexbuf;
      if brace_depth > 0 then begin
        (* Inside expression — toggle string context *)
        Buffer.add_char buf '"';
        read_interp_string prefix buf brace_depth (not in_string) lexbuf
      end else begin
        state.interp_depth <- max 0 (state.interp_depth - 1);
        let rest = Buffer.contents buf in
        mark_direct_token (Parser.STRING_INTERP (prefix ^ rest))
      end
    }
  | "${" {
      update_pos lexbuf;
      if in_string then begin
        (* Inside a nested string — literal text *)
        Buffer.add_string buf "${";
        read_interp_string prefix buf brace_depth in_string lexbuf
      end else begin
        (* New interpolation segment: add { to buffer (interp_parser splits on {) *)
        Buffer.add_char buf '{';
        read_interp_string prefix buf (brace_depth + 1) false lexbuf
      end
    }
  | '{' {
      update_pos lexbuf;
      if in_string then begin
        (* Inside a nested string — literal text *)
        Buffer.add_char buf '{';
        read_interp_string prefix buf brace_depth in_string lexbuf
      end else if brace_depth > 0 then begin
        (* Nested brace inside expression — track depth *)
        Buffer.add_char buf '{';
        read_interp_string prefix buf (brace_depth + 1) false lexbuf
      end else begin
        (* Literal { outside expression — escape so interp_parser doesn't split on it *)
        Buffer.add_string buf "\\{";
        read_interp_string prefix buf brace_depth false lexbuf
      end
    }
  | '}' {
      update_pos lexbuf;
      if in_string then begin
        (* Inside a nested string — literal text *)
        Buffer.add_char buf '}';
        read_interp_string prefix buf brace_depth in_string lexbuf
      end else if brace_depth > 0 then begin
        Buffer.add_char buf '}';
        read_interp_string prefix buf (brace_depth - 1) false lexbuf
      end else begin
        (* Literal } outside expression — escape for consistency *)
        Buffer.add_string buf "\\}";
        read_interp_string prefix buf brace_depth false lexbuf
      end
    }
  | "\\u{" (['0'-'9' 'a'-'f' 'A'-'F']+ as hex) '}' {
      update_pos lexbuf;
      Buffer.add_string buf "\\u{";
      Buffer.add_string buf hex;
      Buffer.add_char buf '}';
      read_interp_string prefix buf brace_depth in_string lexbuf
    }
  | '\\' (_ as c) {
      update_pos lexbuf;
      Buffer.add_char buf '\\';
      Buffer.add_char buf c;
      read_interp_string prefix buf brace_depth in_string lexbuf
    }
  | '$' {
      (* Lone $ not followed by { — literal *)
      update_pos lexbuf;
      Buffer.add_char buf '$';
      read_interp_string prefix buf brace_depth in_string lexbuf
    }
  | [^ '"' '{' '}' '\\' '\n' '$']+ as s {
      update_pos lexbuf;
      Buffer.add_string buf s;
      read_interp_string prefix buf brace_depth in_string lexbuf
    }
  | newline {
      if in_string then
        raise (LexError (Printf.sprintf "Unterminated string inside interpolation expression (started at line %d, column %d)" state.string_start_line state.string_start_col, state.line, state.col))
      else
        raise (LexError (Printf.sprintf "Unterminated interpolated string (started at line %d, column %d). Use aligned pipe strings for multiline text" state.string_start_line state.string_start_col, state.line, state.col))
    }
  | eof {
      raise (LexError (Printf.sprintf "Unterminated interpolated string: missing closing '\"' (started at line %d, column %d)" state.string_start_line state.string_start_col, state.line, state.col))
    }

and read_pipe_line margin_col buf saw_interp raw is_first = parse
  | ([^ '\n' '\r']* as line) newline {
      update_pos lexbuf;
      if not is_first then Buffer.add_char buf '\n';
      let line_saw_interp = append_pipe_line_content ~raw buf line in
      state.at_line_start <- true;
      state.has_token_on_line <- false;
      if next_line_starts_with_pipe_margin lexbuf margin_col then
        read_pipe_margin margin_col buf (saw_interp || line_saw_interp) raw false lexbuf
      else begin
        state.pending_newline <- true;
        pipe_string_token ~raw (Buffer.contents buf) (saw_interp || line_saw_interp)
      end
    }
  | ([^ '\n' '\r']* as line) eof {
      update_pos lexbuf;
      if not is_first then Buffer.add_char buf '\n';
      let line_saw_interp = append_pipe_line_content ~raw buf line in
      pipe_string_token ~raw (Buffer.contents buf) (saw_interp || line_saw_interp)
    }

and read_pipe_margin margin_col buf saw_interp raw is_first = parse
  | whitespace as ws {
      update_pos lexbuf;
      let indent = calc_indent ws in
      if indent <> margin_col - 1 then
        raise (LexError (Printf.sprintf "Misaligned pipe string marker: expected column %d" margin_col, state.line, state.col))
      else
        read_pipe_margin_pipe margin_col buf saw_interp raw is_first lexbuf
    }
  | '|' {
      update_pos lexbuf;
      if margin_col <> 1 then
        raise (LexError (Printf.sprintf "Misaligned pipe string marker: expected column %d" margin_col, state.line, state.col))
      else
        read_pipe_line margin_col buf saw_interp raw is_first lexbuf
    }
  | _ {
      raise (LexError (Printf.sprintf "Expected aligned pipe string marker at column %d" margin_col, state.line, state.col))
    }
  | eof {
      pipe_string_token ~raw (Buffer.contents buf) saw_interp
    }

and read_pipe_margin_pipe margin_col buf saw_interp raw is_first = parse
  | '|' {
      update_pos lexbuf;
      read_pipe_line margin_col buf saw_interp raw is_first lexbuf
    }
  | _ {
      raise (LexError (Printf.sprintf "Expected aligned pipe string marker at column %d" margin_col, state.line, state.col))
    }
  | eof {
      pipe_string_token ~raw (Buffer.contents buf) saw_interp
    }

and read_raw_pipe_start = parse
  | whitespace newline {
      update_pos lexbuf;
      state.at_line_start <- true;
      state.has_token_on_line <- false;
      read_raw_pipe_margin lexbuf
    }
  | newline {
      update_pos lexbuf;
      state.at_line_start <- true;
      state.has_token_on_line <- false;
      read_raw_pipe_margin lexbuf
    }
  | _ {
      raise (LexError ("raw pipe strings must start on the next line", state.line, state.col))
    }
  | eof {
      raise (LexError ("raw pipe strings must start on the next line", state.line, state.col))
    }

and read_raw_pipe_margin = parse
  | whitespace as ws {
      update_pos lexbuf;
      let margin_col = calc_indent ws + 1 in
      read_raw_pipe_marker margin_col lexbuf
    }
  | '|' {
      let margin_col = state.col in
      update_pos lexbuf;
      read_pipe_line margin_col (Buffer.create 256) false true true lexbuf
    }
  | _ {
      raise (LexError ("raw pipe strings must start with an aligned pipe marker", state.line, state.col))
    }
  | eof {
      raise (LexError ("raw pipe strings must start with an aligned pipe marker", state.line, state.col))
    }

and read_raw_pipe_marker margin_col = parse
  | '|' {
      update_pos lexbuf;
      read_pipe_line margin_col (Buffer.create 256) false true true lexbuf
    }
  | _ {
      raise (LexError ("raw pipe strings must start with an aligned pipe marker", state.line, state.col))
    }
  | eof {
      raise (LexError ("raw pipe strings must start with an aligned pipe marker", state.line, state.col))
    }

and read_char = parse
  (* Unicode escape: \u{XXXX} *)
  | "\\u{" (['0'-'9' 'a'-'f' 'A'-'F']+ as hex) "}'" {
      update_pos lexbuf;
      let codepoint = int_of_string ("0x" ^ hex) in
      if codepoint > 0x10FFFF then
        raise (LexError (Printf.sprintf "Unicode codepoint U+%s is out of range (max U+10FFFF)" hex, state.line, state.col))
      else if codepoint >= 0xD800 && codepoint <= 0xDFFF then
        raise (LexError (Printf.sprintf "Unicode codepoint U+%s is a surrogate (U+D800..U+DFFF not allowed)" hex, state.line, state.col))
      else
        mark_direct_token (Parser.CHAR codepoint)
    }
  (* Standard escape sequences *)
  | '\\' (_ as c) '\'' {
      update_pos lexbuf;
      mark_direct_token (Parser.CHAR (Char.code (parse_escape c)))
    }
  (* Simple character — may be multi-byte UTF-8 *)
  | ([^ '\\' '\'']+ as s) '\'' {
      update_pos lexbuf;
      let cp = try decode_utf8_char s
        with Failure _ ->
          raise (LexError (Printf.sprintf "Invalid character literal: '%s' is not a single character. Use double quotes for strings: \"%s\"" s s, state.line, state.col))
      in
      if cp > 0x10FFFF then
        raise (LexError (Printf.sprintf "Unicode codepoint U+%X is out of range (max U+10FFFF)" cp, state.line, state.col));
      if cp >= 0xD800 && cp <= 0xDFFF then
        raise (LexError (Printf.sprintf "Unicode codepoint U+%X is a surrogate (U+D800..U+DFFF not allowed)" cp, state.line, state.col));
      (* Reject multiple ASCII chars like 'ab' — those aren't valid char literals *)
      if String.length s > 1 && cp < 128 then
        raise (LexError (Printf.sprintf "Invalid character literal: '%s' is not a single character. Use double quotes for strings: \"%s\"" s s, state.line, state.col));
      mark_direct_token (Parser.CHAR cp)
    }
  | _ {
      raise (LexError ("Invalid character literal: expected single character between quotes (e.g., 'a')", state.line, state.col))
    }

and read_docstring buf = parse
  | "---" whitespace? newline {
      update_pos lexbuf;
      state.at_line_start <- true;
      state.pending_newline <- true;
      emit_or_pending (Parser.DOCSTRING (Buffer.contents buf))
    }
  | "---" whitespace? eof {
      emit_or_pending (Parser.DOCSTRING (Buffer.contents buf))
    }
  | ([^ '\n']* as line) newline {
      update_pos lexbuf;
      if Buffer.length buf > 0 then Buffer.add_char buf '\n';
      Buffer.add_string buf line;
      read_docstring buf lexbuf
    }
  | eof { raise (LexError ("Unterminated docstring: missing closing ---", state.line, state.col)) }

{
(** Token stream with pending token support *)
let next_token lexbuf =
  let tok = match state.pending_tokens with
  | tok :: rest ->
      state.pending_tokens <- rest;
      tok
  | [] -> token lexbuf
  in
  (* Track last token *)
  state.last_token <- Some tok;
  (* Check if we're exiting a lambda body by dedenting to its starting level *)
  (match tok, state.lambda_body_levels with
   | Parser.DEDENT, (_, indent_level) :: rest ->
       (* Get current indent level after dedent *)
       let current_indent = current_indent () in
       (* If we've dedented to or below the lambda's starting level, pop it *)
       if current_indent <= indent_level then
         state.lambda_body_levels <- rest
   | _ -> ());
  tok

(** Get current position *)
let current_pos () = (state.line, state.col)

(** Get the last token that was emitted *)
let last_token () = state.last_token

(** Convert a token to a human-readable string for error messages *)
let token_to_string = function
  | Parser.FUNC -> "func" | Parser.PURE -> "pure" | Parser.VAR -> "var"
  | Parser.UNION -> "union" | Parser.ENUM -> "enum" | Parser.RECORD -> "record" | Parser.VOID_KW -> "void"
  | Parser.WHILE -> "while" | Parser.FOR -> "for" | Parser.IN -> "in"
  | Parser.IF -> "if" | Parser.ELSE -> "else"
  | Parser.AND -> "and" | Parser.OR -> "or" | Parser.NOT -> "not"
  | Parser.BREAK -> "break" | Parser.CONTINUE -> "continue"
  | Parser.IMPLEMENTS -> "implements" | Parser.TRAIT -> "trait"
  | Parser.SELF_TYPE -> "Self"
  | Parser.TYPE -> "type" | Parser.ALIAS -> "alias" | Parser.BUILTIN -> "builtin"
  | Parser.IMPORT -> "import" | Parser.AS -> "as"
  | Parser.PRIVATE -> "private" | Parser.EXPORT -> "export" | Parser.MATCH -> "match"
  | Parser.TRUE -> "True" | Parser.FALSE -> "False"
  | Parser.IDENT s -> Printf.sprintf "'%s'" s
  | Parser.INT n -> Int64.to_string n
  | Parser.BIGINT n -> n
  | Parser.FLOAT f -> string_of_float f
  | Parser.STRING s -> Printf.sprintf "\"%s\"" (String.sub s 0 (min 20 (String.length s)))
  | Parser.STRING_RAW s -> Printf.sprintf "raw\"%s\"" (String.sub s 0 (min 20 (String.length s)))
  | Parser.STRING_INTERP _ -> "interpolated string"
  | Parser.PIPE_STRING _ -> "multiline string"
  | Parser.PIPE_STRING_RAW _ -> "raw pipe string"
  | Parser.PIPE_STRING_INTERP _ -> "multiline interpolated string"
  | Parser.CHAR _ -> "character literal"
  | Parser.DOCSTRING _ -> "docstring"
  | Parser.LPAREN -> "(" | Parser.RPAREN -> ")"
  | Parser.LBRACKET -> "[" | Parser.RBRACKET -> "]"
  | Parser.LBRACE -> "{" | Parser.RBRACE -> "}"
  | Parser.COLON -> ":" | Parser.COMMA -> ","
  | Parser.DOT -> "." | Parser.DOTDOT -> ".." | Parser.DOTDOTDOT -> "..."
  | Parser.PLUS -> "+" | Parser.MINUS -> "-"
  | Parser.STAR -> "*" | Parser.SLASH -> "/"
  | Parser.UNDERSCORE -> "_" | Parser.PERCENT -> "%"
  | Parser.HASH -> "#" | Parser.AT -> "@"
  | Parser.LT -> "<" | Parser.GT -> ">"
  | Parser.ARROW -> "->" | Parser.FATARROW -> "=>" | Parser.PIPE -> "|"
  | Parser.LE -> "<=" | Parser.GE -> ">="
  | Parser.EQ -> "==" | Parser.NE -> "!="
  | Parser.EQUALS -> "="
  | Parser.PLUS_EQ -> "+=" | Parser.MINUS_EQ -> "-="
  | Parser.STAR_EQ -> "*="
  | Parser.SLASH_EQ -> "/="
  | Parser.QUESTION_EQUALS -> "?="
  | Parser.TRY -> "try" | Parser.WITH -> "with" | Parser.RESOURCE -> "resource" | Parser.DEBUG -> "debug" | Parser.STRUCT -> "struct" | Parser.FOREIGN -> "foreign"
  | Parser.CONCURRENT -> "concurrent" | Parser.CONCURRENTLY -> "concurrently"
  | Parser.SELECT -> "select" | Parser.FROM -> "from"
  | Parser.AFTER -> "after" | Parser.SEALED -> "sealed"
  | Parser.DETACH -> "detach" | Parser.WHERE -> "where"
  | Parser.INDENT -> "indent" | Parser.DEDENT -> "dedent"
  | Parser.NEWLINE -> "newline" | Parser.EOF -> "end of file"

}
