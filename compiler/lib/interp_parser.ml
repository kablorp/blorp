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

type expr_parse_request = { text : string; loc : loc }

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

(** Collect interpolation expression parse requests in source order. *)
let requests_for_raw_string loc raw_str =
  split_interpolated_string ~base_loc:loc raw_str
  |> List.filter_map (fun (is_expr, content) ->
         if is_expr then Some { text = content; loc } else None)

let rec collect_expr_requests acc expr =
  match expr.expr_desc with
  | EStringInterpRaw (raw_str, _) ->
      acc @ requests_for_raw_string expr.expr_loc raw_str
  | _ -> List.fold_left collect_expr_requests acc (expr_children expr)

let collect_func_requests acc func =
  match func_body_expr_opt func.func_body with
  | Some body -> collect_expr_requests acc body
  | None -> acc

let rec collect_decl_requests acc decl =
  match decl.decl_desc with
  | DFunc func -> collect_func_requests acc func
  | DVar var -> collect_expr_requests acc var.var_value
  | DPrivate inner -> collect_decl_requests acc inner
  | DImpl impl -> List.fold_left collect_func_requests acc impl.impl_methods
  | DTrait trait ->
      List.fold_left
        (fun acc method_decl ->
          match method_decl.method_default_body with
          | Some body -> collect_expr_requests acc body
          | None -> acc)
        acc trait.trait_methods
  | DType _ | DRecord _ | DImport _ | DTypeAlias _ -> acc

let collect_program_requests program =
  List.fold_left collect_decl_requests [] program

let parse_batch_checked parse_batch requests =
  match requests with
  | [] -> []
  | first :: _ ->
      let parsed = parse_batch requests in
      if List.length parsed = List.length requests then parsed
      else
        raise
          (InterpParseError
             ( "interpolation expression parser returned the wrong number of \
                expressions",
               first.loc ))

let rec relocate_expr_tree loc expr =
  { (expr_map_children (relocate_expr_tree loc) expr) with expr_loc = loc }

let same_expr_parse_request (left : expr_parse_request)
    (right : expr_parse_request) =
  String.equal left.text right.text && left.loc = right.loc

let take_parsed_expr_for_request parsed_queue request =
  let rec loop skipped = function
    | [] ->
        raise
          (InterpParseError
             ( Printf.sprintf "Failed to parse interpolated expression: %s"
                 request.text,
               request.loc ))
    | (candidate, parsed) :: rest ->
        if same_expr_parse_request candidate request then
          (parsed, List.rev_append skipped rest)
        else loop ((candidate, parsed) :: skipped) rest
  in
  let parsed, remaining = loop [] !parsed_queue in
  parsed_queue := remaining;
  parsed

(** Transform an expression using already parsed interpolation-hole
    expressions. Requests are matched by source text and containing string
    location instead of traversal position because nested constructs can
    reorder raw-string discovery relative to AST rewriting. Nested interpolation
    found inside parsed expressions is transformed through a fresh batch. *)
let rec transform_expr_consuming_batch parse_batch parsed_queue expr =
  let loc = expr.expr_loc in
  match expr.expr_desc with
  | EStringInterpRaw (raw_str, is_multiline) ->
      let raw_parts = split_interpolated_string ~base_loc:loc raw_str in
      let parts =
        List.map
          (fun (is_expr, content) ->
            if is_expr then
              let parsed =
                take_parsed_expr_for_request parsed_queue { text = content; loc }
              in
              InterpExpr
                (transform_expr_with_expr_batch_parser parse_batch
                   (relocate_expr_tree loc parsed))
            else InterpLit content)
          raw_parts
      in
      { expr with expr_desc = EStringInterp (parts, is_multiline) }
  | _ ->
      expr_map_children
        (transform_expr_consuming_batch parse_batch parsed_queue)
        expr

and transform_expr_with_expr_batch_parser parse_batch expr =
  let requests = collect_expr_requests [] expr in
  match requests with
  | [] -> expr
  | _ ->
      let parsed_queue =
        ref (List.combine requests (parse_batch_checked parse_batch requests))
      in
      transform_expr_consuming_batch parse_batch parsed_queue expr

and transform_func_consuming_batch parse_batch parsed_queue func =
  {
    func with
    func_body =
      map_func_body_expr
        (transform_expr_consuming_batch parse_batch parsed_queue)
        func.func_body;
  }

and transform_decl_consuming_batch parse_batch parsed_queue decl =
  match decl.decl_desc with
  | DFunc func ->
      {
        decl with
        decl_desc =
          DFunc (transform_func_consuming_batch parse_batch parsed_queue func);
      }
  | DVar var ->
      {
        decl with
        decl_desc =
          DVar
            {
              var with
              var_value =
                transform_expr_consuming_batch parse_batch parsed_queue
                  var.var_value;
            };
      }
  | DPrivate inner ->
      {
        decl with
        decl_desc =
          DPrivate (transform_decl_consuming_batch parse_batch parsed_queue inner);
      }
  | DImpl impl ->
      {
        decl with
        decl_desc =
          DImpl
            {
              impl with
              impl_methods =
                List.map
                  (transform_func_consuming_batch parse_batch parsed_queue)
                  impl.impl_methods;
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
                        Option.map
                          (transform_expr_consuming_batch parse_batch parsed_queue)
                          m.method_default_body;
                    })
                  trait.trait_methods;
            };
      }
  | DType _ | DRecord _ | DImport _ | DTypeAlias _ -> decl

let transform_program_with_expr_batch_parser parse_batch program =
  let requests = collect_program_requests program in
  match requests with
  | [] -> program
  | _ ->
      let parsed_queue =
        ref (List.combine requests (parse_batch_checked parse_batch requests))
      in
      List.map (transform_decl_consuming_batch parse_batch parsed_queue) program

(** Transform a program, converting all EStringInterpRaw to EStringInterp.
    Must be called after parsing but before type checking. *)
let transform_program_with_expr_parser parse_expr (program : program) : program =
  transform_program_with_expr_batch_parser
    (fun requests ->
      List.map (fun request -> parse_expr request.text request.loc) requests)
    program
