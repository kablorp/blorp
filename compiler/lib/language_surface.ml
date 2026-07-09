(** Phase-neutral facts about Blorp's source language surface.

    Blorp owns the source-language tables in
    [compiler/blorp/src/stage_05_types/language_surface_manifest.brp]. This OCaml module is only
    the typed facade used by parser-adjacent, typecheck, LSP, and tooling code.
    The OCaml data is generated from that Blorp manifest at build time so
    remaining OCaml consumers do not shell through the compiler bridge for
    static tables. *)

(** User-facing keywords worth suggesting in editor completions.

    Keep legacy/error-only lexer tokens out of this list. For example, [try] and
    [export] are still lexed so the parser can produce specific removal errors,
    but completions should not advertise removed syntax. *)
let lsp_completion_keywords () =
  Language_surface_data.lsp_completion_keywords

let prelude_method_type_imports () =
  Language_surface_data.prelude_method_type_imports

let prelude_ufcs_modules () =
  Language_surface_data.prelude_ufcs_modules
