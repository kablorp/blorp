(** JSON projection for formatter docstrings.

    Plain docstrings stay plain text. Docstrings with a recognized [doctests:]
    section are projected into prefix text plus doctest groups. OCaml parses the
    embedded code snippets so the Blorp renderer can format them from expression
    JSON instead of inheriting rendered text from the legacy OCaml printer. *)

let string = Fmt_expr_json.string
let field = Fmt_expr_json.field
let obj = Fmt_expr_json.obj
let array = Fmt_expr_json.array
let string_array values = array (List.map string values)
let doctest_header = "doctests:"
let doctest_indent = "    "

let string_starts_with s prefix =
  let s_len = String.length s in
  let prefix_len = String.length prefix in
  s_len >= prefix_len && String.sub s 0 prefix_len = prefix

let drop_leading_blank lines =
  let rec drop = function
    | line :: rest when String.trim line = "" -> drop rest
    | lines -> lines
  in
  drop lines

let strip_blank_edges lines =
  let leading = drop_leading_blank lines in
  List.rev (drop_leading_blank (List.rev leading))

let strip_doctest_indent line =
  let len = String.length line in
  let indent_len = String.length doctest_indent in
  if len >= indent_len && String.sub line 0 indent_len = doctest_indent then
    String.sub line indent_len (len - indent_len)
  else if len >= 1 && line.[0] = '\t' then String.sub line 1 (len - 1)
  else line

let is_delimiter line =
  let trimmed = String.trim line in
  string_starts_with trimmed "::"

let delimiter_desc line =
  let trimmed = String.trim line in
  String.trim (String.sub trimmed 2 (String.length trimmed - 2))

let split_prefix lines =
  let rec loop acc = function
    | [] -> None
    | line :: rest when String.trim line = doctest_header ->
        Some (List.rev acc, rest)
    | line :: rest -> loop (line :: acc) rest
  in
  loop [] lines

let finish_group current_desc current_code groups =
  match current_desc with
  | Some desc -> (desc, List.rev current_code) :: groups
  | None -> groups

let split_groups lines =
  let rec loop current_desc current_code groups = function
    | [] ->
        let groups = finish_group current_desc current_code groups in
        Some (List.rev groups)
    | line :: rest -> (
        if is_delimiter line then
          let groups = finish_group current_desc current_code groups in
          loop (Some (delimiter_desc line)) [] groups rest
        else
          match current_desc with
          | Some _ -> loop current_desc (line :: current_code) groups rest
          | None when String.trim line = "" -> loop None [] groups rest
          | None -> None)
  in
  loop None [] [] lines

let separate_imports lines =
  match lines with
  | first :: rest when String.trim first = "import:" ->
      let rec consume acc = function
        | line :: remaining
          when string_starts_with line doctest_indent && String.trim line <> ""
          ->
            consume ((doctest_indent ^ String.trim line) :: acc) remaining
        | remaining -> (List.rev acc, remaining)
      in
      let imports, remaining = consume [] rest in
      (first :: imports, remaining)
  | _ -> ([], lines)

let parse_format_snippet source =
  try
    Lexer.reset_state ();
    let lexbuf = Lexing.from_string source in
    let program = Parser.program Lexer.next_token lexbuf in
    Some (Interp_parser.transform_program program, Lexer.get_comments ())
  with
  | Parser.Error | Lexer.LexError _ | Ast.Parse_error_at _ -> None
  | Failure _ | Invalid_argument _ -> None

let parsed_body_json code_lines =
  let body_line line =
    if String.trim line = "" then "\n" else "\t" ^ line ^ "\n"
  in
  let source =
    "func __doctest__():\n" ^ String.concat "" (List.map body_line code_lines)
  in
  match parse_format_snippet source with
  | Some
      ( [
          {
            Ast.decl_desc = Ast.DFunc { func_body = Ast.FuncBodyExpr body; _ };
            _;
          };
        ],
        collected ) ->
      Fmt_expr_json.with_comments collected (fun () ->
          Fmt_expr_json.expr_to_json body)
  | _ -> None

let doctest_group_json (description, code_lines) =
  let cleaned = strip_blank_edges code_lines in
  let imports, body = separate_imports cleaned in
  match parsed_body_json (strip_blank_edges body) with
  | Some body_json ->
      obj
        [
          field "description" (string description);
          field "imports" (string_array imports);
          field "body" body_json;
        ]
  | None ->
      obj
        [
          field "description" (string description);
          field "imports" (string_array []);
          field "raw_body" (string_array cleaned);
        ]

let plain_doc_json doc =
  obj [ field "tag" (string "Plain"); field "text" (string doc) ]

let doctest_doc_json prefix groups =
  obj
    [
      field "tag" (string "Doctests");
      field "prefix" (string_array prefix);
      field "groups" (array (List.map doctest_group_json groups));
    ]

let doc_to_json doc =
  let lines = String.split_on_char '\n' doc in
  match split_prefix lines with
  | None -> plain_doc_json doc
  | Some (prefix, rest) -> (
      let stripped = List.map strip_doctest_indent rest in
      match split_groups stripped with
      | None | Some [] -> plain_doc_json doc
      | Some groups -> doctest_doc_json prefix groups)
