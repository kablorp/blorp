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
       ])

let render_surface op =
  match List.assoc_opt op (Lazy.force surface_rows) with
  | Some text -> text
  | None -> invalid_arg ("missing language surface row: " ^ op)

let split_semicolon_table text =
  if String.equal text "" then [] else String.split_on_char ';' text

let split_pair entry =
  Compiler_blorp_bridge.parse_colon_pair_exn
    ~label:"language-surface prelude method import" entry

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
  let rec add_seen seen acc = function
    | [] -> List.rev acc
    | (module_name, _) :: rest ->
        if List.mem module_name seen then add_seen seen acc rest
        else add_seen (module_name :: seen) (module_name :: acc) rest
  in
  add_seen [] [] (prelude_method_type_imports ())
