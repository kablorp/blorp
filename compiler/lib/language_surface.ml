(** Phase-neutral facts about Blorp's source language surface.

    Keep this module small and dependency-free so parser-adjacent, typecheck,
    LSP, and tooling code can share names without creating phase coupling. *)

(** User-facing keywords worth suggesting in editor completions.

    Keep legacy/error-only lexer tokens out of this list. For example, [try] and
    [export] are still lexed so the parser can produce specific removal errors,
    but completions should not advertise removed syntax. *)
let lsp_completion_keywords =
  [
    "func";
    "pure";
    "var";
    "union";
    "record";
    "void";
    "while";
    "for";
    "in";
    "if";
    "else";
    "and";
    "or";
    "not";
    "match";
    "True";
    "False";
    "break";
    "continue";
    "debug";
    "struct";
    "enum";
    "with";
    "resource";
    "foreign";
    "private";
    "builtin";
    "concurrent";
    "concurrently";
    "detach";
    "select";
    "into";
    "from";
    "after";
    "sealed";
    "import";
    "as";
    "trait";
    "implements";
    "Self";
    "type";
    "alias";
    "where";
  ]

let prelude_method_type_imports =
  [
    ("option", "Option");
    ("result", "Result");
    ("bool", "Bool");
    ("char", "Char");
    ("bytes", "Bytes");
    ("string", "String");
    ("list", "List");
    ("list", "ParallelList");
    ("parallel_list", "ParallelList");
    ("vector", "ParallelVector");
    ("parallel_vector", "ParallelVector");
    ("matrix", "ParallelMatrix");
    ("parallel_matrix", "ParallelMatrix");
    ("range", "Range");
    ("dict", "Dict");
    ("set", "Set");
    ("file", "FileReader");
    ("file", "FileWriter");
    ("file", "FileAppender");
    ("file", "FileReadWriter");
    ("file", "FileReadAppender");
  ]

let prelude_ufcs_modules =
  let rec add_seen seen acc = function
    | [] -> List.rev acc
    | (module_name, _) :: rest ->
        if List.mem module_name seen then add_seen seen acc rest
        else add_seen (module_name :: seen) (module_name :: acc) rest
  in
  add_seen [] [] prelude_method_type_imports
