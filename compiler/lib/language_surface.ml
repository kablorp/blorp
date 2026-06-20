(** Phase-neutral facts about Blorp's source language surface.

    Blorp owns the source-language tables in
    [compiler/blorp/language_surface_manifest.brp]. This OCaml module is only
    the typed facade used by parser-adjacent, typecheck, LSP, and tooling code.
    Fetch the whole table through one JSON command handoff so this slice has
    the same transport shape the broader compiler migration is moving toward. *)

let surface_rows =
  lazy
    (Compiler_blorp_bridge.render_many_via_command_exn
       ~renderer:Compiler_blorp_bridge.language_surface_renderer
       [
         ("language_lsp_completion_keywords", []);
         ("language_prelude_method_type_imports", []);
         ("language_prelude_ufcs_modules", []);
       ])

let render_surface op =
  match List.assoc_opt op (Lazy.force surface_rows) with
  | Some text -> text
  | None -> invalid_arg ("missing language surface row: " ^ op)

let split_semicolon_table text =
  if String.equal text "" then [] else String.split_on_char ';' text

let split_pair entry =
  try
    let index = String.index entry ':' in
    let left = String.sub entry 0 index in
    let right =
      String.sub entry (index + 1) (String.length entry - index - 1)
    in
    if String.equal left "" || String.equal right "" then
      invalid_arg
        ("invalid language-surface prelude method import entry: " ^ entry)
    else (left, right)
  with Not_found ->
    invalid_arg
      ("invalid language-surface prelude method import entry: " ^ entry)

(** User-facing keywords worth suggesting in editor completions.

    Keep legacy/error-only lexer tokens out of this list. For example, [try] and
    [export] are still lexed so the parser can produce specific removal errors,
    but completions should not advertise removed syntax. *)
let lsp_completion_keywords () =
  render_surface "language_lsp_completion_keywords" |> split_semicolon_table

let prelude_method_type_imports () =
  render_surface "language_prelude_method_type_imports"
  |> split_semicolon_table |> List.map split_pair

let prelude_ufcs_modules () =
  render_surface "language_prelude_ufcs_modules" |> split_semicolon_table
