(** Interpolated String Parser

    Parses the raw content of an interpolated string into a list of parts.
    The input is a string like "Hello {name}! You are {age} years old."
    where the braces and their contents are literal text from the lexer.

    This module provides a pure string parsing function that splits the
    interpolated string content into literal and expression-text parts.
    The actual expression parsing is done by transform_program which must
    be called after the main parser but before type checking.
*)

open Ast

exception InterpParseError of string * loc
(** Parse error with message and location *)

(** Split an interpolated string into literal and expression-text parts.
    The input string contains literal text and {expr} sequences.
    The lexer has already consumed the $\{ prefix, so raw content uses {expr}.
    Returns a list of (is_expr, content) pairs where is_expr=true means
    it's an expression to be parsed, and is_expr=false means literal text. *)
let split_interpolated_string ~(base_loc : loc) (s : string) :
    (bool * string) list =
  let len = String.length s in
  let parts = ref [] in
  let buf = Buffer.create 64 in
  let i = ref 0 in

  (* Flush accumulated literal to parts list *)
  let flush_lit () =
    if Buffer.length buf > 0 then begin
      parts := (false, Buffer.contents buf) :: !parts;
      Buffer.clear buf
    end
  in

  while !i < len do
    let c = s.[!i] in
    if c = '\\' && !i + 1 < len then begin
      (* Escape sequence *)
      let next = s.[!i + 1] in
      match next with
      | 'n' ->
          Buffer.add_char buf '\n';
          i := !i + 2
      | 't' ->
          Buffer.add_char buf '\t';
          i := !i + 2
      | 'r' ->
          Buffer.add_char buf '\r';
          i := !i + 2
      | '\\' ->
          Buffer.add_char buf '\\';
          i := !i + 2
      | '"' ->
          Buffer.add_char buf '"';
          i := !i + 2
      | '\'' ->
          Buffer.add_char buf '\'';
          i := !i + 2
      | '0' ->
          Buffer.add_char buf '\000';
          i := !i + 2
      | '{' ->
          Buffer.add_char buf '{';
          i := !i + 2
      | '}' ->
          Buffer.add_char buf '}';
          i := !i + 2
      | 'u' when !i + 2 < len && s.[!i + 2] = '{' ->
          (* \u{XXXX} unicode escape *)
          let start = !i + 3 in
          let j = ref start in
          while !j < len && s.[!j] <> '}' do
            incr j
          done;
          if !j >= len then begin
            Buffer.add_char buf c;
            incr i (* malformed, pass through *)
          end
          else begin
            let hex_str = String.sub s start (!j - start) in
            let cp = try int_of_string ("0x" ^ hex_str) with _ -> -1 in
            if cp >= 0 && cp <= 0x10FFFF && not (cp >= 0xD800 && cp <= 0xDFFF)
            then begin
              (* UTF-8 encode *)
              if cp < 0x80 then Buffer.add_char buf (Char.chr cp)
              else if cp < 0x800 then begin
                Buffer.add_char buf (Char.chr (0xC0 lor (cp lsr 6)));
                Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
              end
              else if cp < 0x10000 then begin
                Buffer.add_char buf (Char.chr (0xE0 lor (cp lsr 12)));
                Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
                Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
              end
              else begin
                Buffer.add_char buf (Char.chr (0xF0 lor (cp lsr 18)));
                Buffer.add_char buf
                  (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
                Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
                Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
              end;
              i := !j + 1
            end
            else begin
              Buffer.add_char buf c;
              incr i (* invalid codepoint, pass through *)
            end
          end
      | _ ->
          Buffer.add_char buf c;
          incr i
    end
    else if c = '{' then begin
      (* Start of interpolated expression *)
      flush_lit ();
      incr i;
      (* Find matching } accounting for nested braces and string literals *)
      let expr_buf = Buffer.create 32 in
      let depth = ref 1 in
      let in_str = ref false in
      while !depth > 0 && !i < len do
        let c = s.[!i] in
        if c = '\\' && !i + 1 < len then begin
          (* Escape sequence — skip both chars *)
          Buffer.add_char expr_buf c;
          Buffer.add_char expr_buf s.[!i + 1];
          i := !i + 2
        end
        else if c = '"' then begin
          in_str := not !in_str;
          Buffer.add_char expr_buf c;
          incr i
        end
        else if !in_str then begin
          (* Inside string — don't track braces *)
          Buffer.add_char expr_buf c;
          incr i
        end
        else if c = '{' then begin
          incr depth;
          Buffer.add_char expr_buf c;
          incr i
        end
        else if c = '}' then begin
          decr depth;
          if !depth > 0 then Buffer.add_char expr_buf c;
          incr i
        end
        else begin
          Buffer.add_char expr_buf c;
          incr i
        end
      done;
      if !depth > 0 then
        raise
          (InterpParseError ("Unclosed '${' in string interpolation", base_loc));
      let expr_str = Buffer.contents expr_buf in
      parts := (true, expr_str) :: !parts
    end
    else begin
      Buffer.add_char buf c;
      incr i
    end
  done;

  flush_lit ();
  List.rev !parts

(** Parse a single expression string into an AST expression.
    This is called during the transformation pass. *)
let parse_expr_string (s : string) (base_loc : loc) : expr =
  try
    (* Parse just a single expression - we need to handle this specially
       since Parser.program expects declarations.
       For interpolation, we create a temporary wrapper and extract the expr. *)
    let wrapper = Printf.sprintf "___interp_temp = %s\n" s in
    let saved_comments = Lexer.get_comments () in
    Lexer.reset_state ();
    let lexbuf = Lexing.from_string wrapper in
    let program = Parser.program Lexer.next_token lexbuf in
    Lexer.restore_comments saved_comments;
    match program with
    | [ { decl_desc = DVar { var_value; _ }; _ } ] -> var_value
    | _ ->
        raise
          (InterpParseError
             ( Printf.sprintf "Failed to parse interpolated expression: %s" s,
               base_loc ))
  with
  | Parser.Error ->
      raise
        (InterpParseError
           ( Printf.sprintf "Parse error in interpolated expression: %s" s,
             base_loc ))
  | Lexer.LexError (msg, _, _) ->
      raise
        (InterpParseError
           ( Printf.sprintf "Lexer error in interpolated expression: %s" msg,
             base_loc ))

(** Transform an expression, converting EStringInterpRaw to EStringInterp *)
let rec transform_expr (expr : expr) : expr =
  let loc = expr.expr_loc in
  match expr.expr_desc with
  | EStringInterpRaw (raw_str, is_triple) ->
      (* Parse the raw string into parts *)
      let raw_parts = split_interpolated_string ~base_loc:loc raw_str in
      let parts =
        List.map
          (fun (is_expr, content) ->
            if is_expr then
              InterpExpr (transform_expr (parse_expr_string content loc))
            else InterpLit content)
          raw_parts
      in
      { expr with expr_desc = EStringInterp (parts, is_triple) }
  (* All other expressions: recursively transform children *)
  | _ -> expr_map_children transform_expr expr

and transform_func (func : func_decl) : func_decl =
  { func with func_body = map_func_body_expr transform_expr func.func_body }

(** Transform a declaration *)
let rec transform_decl (decl : decl) : decl =
  match decl.decl_desc with
  | DFunc func -> { decl with decl_desc = DFunc (transform_func func) }
  | DVar var ->
      {
        decl with
        decl_desc = DVar { var with var_value = transform_expr var.var_value };
      }
  | DPrivate inner -> { decl with decl_desc = DPrivate (transform_decl inner) }
  | DImpl impl ->
      {
        decl with
        decl_desc =
          DImpl
            {
              impl with
              impl_methods = List.map transform_func impl.impl_methods;
            };
      }
  | DTrait trait ->
      {
        decl with
        decl_desc =
          DTrait
            {
              trait with
              trait_methods =
                List.map
                  (fun m ->
                    {
                      m with
                      method_default_body =
                        Option.map transform_expr m.method_default_body;
                    })
                  trait.trait_methods;
            };
      }
  (* No expressions to transform *)
  | DType _ | DRecord _ | DImport _ | DTypeAlias _ -> decl

(** Transform a program, converting all EStringInterpRaw to EStringInterp.
    Must be called after parsing but before type checking. *)
let transform_program (program : program) : program =
  List.map transform_decl program
