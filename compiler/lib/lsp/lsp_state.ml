(** LSP document state management and analysis pipeline.

    Tracks open documents, runs the compiler pipeline on changes,
    and publishes diagnostics. Position lookup and hover info
    are in Lsp_position and Lsp_hover respectively. *)

open Ast
open Lsp_json

(* ============================================================================
   Document state
   ============================================================================ *)

type document = {
  uri : string;
  version : int;
  text : string;
  mutable diagnostics : compiler_error list;
  mutable parse_errors : string list;
  mutable source_program : program option;
  mutable program : program option;
  mutable typed_program : Typed_ast.program option;
  mutable env : Env.env option;
  mutable module_aliases : (string * string) list;
}

type state = {
  documents : (string, document) Hashtbl.t;
  mutable initialized : bool;
}

let create () : state = { documents = Hashtbl.create 16; initialized = false }
let find_document state uri = Hashtbl.find_opt state.documents uri

let clear_analysis_state doc =
  doc.parse_errors <- [];
  doc.source_program <- None;
  doc.program <- None;
  doc.typed_program <- None;
  doc.env <- None;
  doc.module_aliases <- []

let module_aliases_of_program (program : program) =
  (* Qualified imports always expose a module name/alias. Selective imports
     expose a qualifier only when the import has an explicit alias, as in
     `option as O: Option`. *)
  List.filter_map
    (fun (d : decl) ->
      match d.decl_desc with
      | DImport { import_module; import_symbols; import_alias; _ } -> (
          match (import_alias, import_symbols) with
          | Some alias, _ -> Some (alias, import_module)
          | None, None -> Some (Filename.basename import_module, import_module)
          | None, Some _ -> None)
      | _ -> None)
    program

(* ============================================================================
   Analysis pipeline — reuses the existing compiler pipeline
   ============================================================================ *)

let init_module_paths = Modules.init_module_paths

(** Run the full analysis pipeline on a document.
    Collects parse errors, type errors, and module errors. *)
let analyze (_state : state) (doc : document) : unit =
  let path = Lsp_protocol.uri_to_path doc.uri in
  let base_dir = Filename.dirname path in
  let base_dir = if base_dir = "" then "." else base_dir in

  (* Reset state for fresh analysis — full_reset clears parse cache
     so that edited module files are re-parsed *)
  Modules.full_reset ();
  Lexer.reset_state ();

  (* Phase 1: Parse *)
  let parse_result =
    match Modules.parse_source ~filename:path doc.text with
    | Ok program -> Ok program
    | Error err -> Error [ err ]
  in

  match parse_result with
  | Error errs ->
      clear_analysis_state doc;
      doc.diagnostics <- errs;
      doc.parse_errors <- List.map (fun e -> e.message) errs
  | Ok program ->
      doc.parse_errors <- [];
      doc.source_program <- Some program;
      doc.program <- Some program;
      doc.typed_program <- None;
      doc.module_aliases <- [];

      (* Phase 2: Load modules *)
      init_module_paths base_dir;
      let _modules = Modules.load_imports program base_dir in
      let module_errors = List.rev (Modules.get_load_errors ()) in

      (* Phase 3: Type check. Keep the parsed AST only on error; successful
         analysis stores the validated typed compatibility view for hover and
         definition lookup. *)
      let type_errors, env =
        match Typecheck.typecheck_with_env_typed program with
        | Ok (typed_program, env) ->
            doc.typed_program <- Some typed_program;
            doc.program <- Some (Typed_ast.program_ast typed_program);
            ([], env)
        | Error (errors, env) ->
            doc.typed_program <- None;
            (errors, env)
      in
      doc.env <- Some env;
      doc.diagnostics <- module_errors @ type_errors;
      doc.module_aliases <- module_aliases_of_program program

(* ============================================================================
   Diagnostics publishing
   ============================================================================ *)

(** Build the diagnostics JSON for a document *)
let get_diagnostics_json doc : json =
  let diags =
    List.map Lsp_protocol.compiler_error_to_diagnostic doc.diagnostics
  in
  Lsp_protocol.publish_diagnostics ~uri:doc.uri ~diagnostics:diags
