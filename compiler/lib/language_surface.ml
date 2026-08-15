(** Phase-neutral facts about Blorp's source language surface.

    Blorp owns the source-language tables in
    [compiler/blorp/src/stage_05_types/language_surface_manifest.brp]. This OCaml module is only
    the typed facade used by parser-adjacent, typecheck, and tooling code.
    The OCaml data is generated from that Blorp manifest at build time so
    remaining OCaml consumers do not shell through the compiler bridge for
    static tables. *)

let prelude_method_type_imports () =
  Language_surface_data.prelude_method_type_imports

let prelude_ufcs_modules () =
  Language_surface_data.prelude_ufcs_modules
