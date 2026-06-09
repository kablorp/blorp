(** LSP protocol types, serialization, and server capabilities.

    Defines the subset of the Language Server Protocol needed for
    diagnostics, hover, definition, declaration, type definition, completion,
    document symbols, and signature help. *)

open Lsp_json

(* ============================================================================
   URI helpers
   ============================================================================ *)

let has_prefix ~prefix s =
  let prefix_len = String.length prefix in
  String.length s >= prefix_len && String.sub s 0 prefix_len = prefix

let is_uri_path_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '/' | '-' | '_' | '.' | '~' | ':' ->
      true
  | _ -> false

let percent_encode_path path =
  let buf = Buffer.create (String.length path) in
  String.iter
    (fun c ->
      if is_uri_path_char c then Buffer.add_char buf c
      else Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c)))
    path;
  Buffer.contents buf

let percent_decode encoded =
  let buf = Buffer.create (String.length encoded) in
  let len = String.length encoded in
  let i = ref 0 in
  while !i < len do
    if encoded.[!i] = '%' && !i + 2 < len then begin
      let hex = String.sub encoded (!i + 1) 2 in
      (try
         let code = int_of_string ("0x" ^ hex) in
         Buffer.add_char buf (Char.chr code)
       with _ ->
         Buffer.add_char buf '%';
         Buffer.add_string buf hex);
      i := !i + 3
    end
    else begin
      Buffer.add_char buf encoded.[!i];
      i := !i + 1
    end
  done;
  Buffer.contents buf

(** Convert a filesystem path to a file:// URI. Absolutizes relative paths
    using the current working directory so IDEs can locate the target file. *)
let path_to_uri path =
  let absolute =
    if Filename.is_relative path then
      Filename.concat (try Sys.getcwd () with _ -> ".") path
    else path
  in
  "file://" ^ percent_encode_path absolute

(** Convert a file:// URI to a filesystem path *)
let uri_to_path uri =
  let prefix = "file://" in
  let prefix_len = String.length prefix in
  if has_prefix ~prefix uri then
    let encoded = String.sub uri prefix_len (String.length uri - prefix_len) in
    let localhost_prefix = "localhost/" in
    let encoded_path =
      if has_prefix ~prefix:localhost_prefix encoded then
        String.sub encoded
          (String.length "localhost")
          (String.length encoded - String.length "localhost")
      else encoded
    in
    percent_decode encoded_path
  else uri

(* ============================================================================
   LSP position/range types
   ============================================================================ *)

type position = { line : int; character : int }
(** LSP position (0-based line and character) *)

type range = { start : position; end_ : position }
(** LSP range *)

(** Convert a blorp loc (1-based) to an LSP position (0-based) *)
let loc_to_position (loc : Ast.loc) : position =
  { line = max 0 (loc.line - 1); character = max 0 (loc.column - 1) }

(** Convert a blorp source location to an LSP range. *)
let loc_to_range (loc : Ast.loc) : range =
  let pos = loc_to_position loc in
  let span_end =
    { line = max 0 (loc.end_line - 1); character = max 0 (loc.end_column - 1) }
  in
  let end_ =
    if
      loc.end_line > loc.line
      || (loc.end_line = loc.line && loc.end_column > loc.column)
    then span_end
    else { pos with character = pos.character + 1 }
  in
  { start = pos; end_ }

let position_to_json (p : position) : json =
  Object [ ("line", Int p.line); ("character", Int p.character) ]

let range_to_json (r : range) : json =
  Object
    [ ("start", position_to_json r.start); ("end", position_to_json r.end_) ]

(* ============================================================================
   Diagnostics
   ============================================================================ *)

type diagnostic_severity = Error | Warning | Information | Hint

let severity_to_int = function
  | Error -> 1
  | Warning -> 2
  | Information -> 3
  | Hint -> 4

let diagnostic_to_json ~range ~severity ~message ~source : json =
  Object
    [
      ("range", range_to_json range);
      ("severity", Int (severity_to_int severity));
      ("source", String source);
      ("message", String message);
    ]

let compiler_error_message (err : Ast.compiler_error) =
  let notes = List.map (fun note -> "note: " ^ note) err.notes in
  let help =
    match err.help with Some help -> [ "help: " ^ help ] | None -> []
  in
  String.concat "\n" ((err.message :: notes) @ help)

(** Convert a compiler_error to an LSP diagnostic *)
let compiler_error_to_diagnostic (err : Ast.compiler_error) : json =
  let range = loc_to_range err.loc in
  diagnostic_to_json ~range ~severity:Error
    ~message:(compiler_error_message err)
    ~source:"blorp"

(** Build a publishDiagnostics notification *)
let publish_diagnostics ~uri ~diagnostics : json =
  Object [ ("uri", String uri); ("diagnostics", Array diagnostics) ]

(* ============================================================================
   Hover
   ============================================================================ *)

(** Build a hover response with markdown content *)
let hover_response ~contents ~range : json =
  Object
    [
      ( "contents",
        Object [ ("kind", String "markdown"); ("value", String contents) ] );
      ("range", range_to_json range);
    ]

(* ============================================================================
   Definition
   ============================================================================ *)

(** Build an LSP Location object *)
let location_json ~uri ~range : json =
  Object [ ("uri", String uri); ("range", range_to_json range) ]

(** Build an LSP LocationLink object.

    JetBrains' LSP navigation path relies on [originSelectionRange] when
    resolving Cmd+Click references, so definition-like responses use links
    instead of plain locations. *)
let location_link_json ?origin_selection_range ~target_uri ~target_range
    ~target_selection_range () : json =
  let base_fields =
    [
      ("targetUri", String target_uri);
      ("targetRange", range_to_json target_range);
      ("targetSelectionRange", range_to_json target_selection_range);
    ]
  in
  let fields =
    match origin_selection_range with
    | None -> base_fields
    | Some range -> ("originSelectionRange", range_to_json range) :: base_fields
  in
  Object fields

(* ============================================================================
   Server capabilities
   ============================================================================ *)

let capabilities : json =
  Object
    [
      ( "textDocumentSync",
        Object
          [
            ("openClose", Bool true);
            ("change", Int 1);
            (* Full document sync *)
            ("save", Object [ ("includeText", Bool true) ]);
          ] );
      ("hoverProvider", Bool true);
      ("documentFormattingProvider", Bool false);
      ("definitionProvider", Bool true);
      ("declarationProvider", Bool true);
      ("typeDefinitionProvider", Bool true);
      ("referencesProvider", Bool true);
      ("documentHighlightProvider", Bool true);
      ("inlayHintProvider", Object [ ("resolveProvider", Bool false) ]);
      ( "completionProvider",
        Object
          [
            ("triggerCharacters", Array [ String "." ]);
            ("resolveProvider", Bool false);
          ] );
      ("documentSymbolProvider", Bool true);
      ( "signatureHelpProvider",
        Object [ ("triggerCharacters", Array [ String "("; String "," ]) ] );
    ]

(* ============================================================================
   Parse LSP position from JSON
   ============================================================================ *)

let position_of_json j : position option =
  match (get_int "line" j, get_int "character" j) with
  | Some line, Some character -> Some { line; character }
  | _ -> None

(* ============================================================================
   Shared helpers — reduce duplication across LSP handlers
   ============================================================================ *)

(** Extract URI string from a textDocument JSON object *)
let get_uri td = match get_string "uri" td with Some u -> u | None -> ""

(** Format type parameters as "[A, B]" or "" *)
let format_type_params = function
  | [] -> ""
  | ps -> "[" ^ String.concat ", " ps ^ "]"

(** Format constructor/variant fields as "(Int, String)" or "" *)
let format_field_types = function
  | [] -> ""
  | fs -> "(" ^ String.concat ", " (List.map Types.type_to_string fs) ^ ")"

(** Format a func_decl as a human-readable signature.
    Returns (label, param_strings) where label is the full signature
    and param_strings are the individual "name: Type" strings. *)
let format_func_decl (fd : Ast.func_decl) (name : string) : string * string list
    =
  let pure_str = if fd.func_is_pure then "pure " else "" in
  let params =
    List.map
      (fun (p : Ast.param) ->
        let n = match p.param_name with Some n -> n | None -> "_" in
        match p.param_type with
        | Some ty -> n ^ ": " ^ Types.type_to_string ty
        | None -> n)
      fd.func_params
  in
  let ret =
    match fd.func_return_type with
    | Some ty -> " -> " ^ Types.type_to_string ty
    | None -> ""
  in
  let label =
    Printf.sprintf "%sfunc %s(%s)%s" pure_str name
      (String.concat ", " params)
      ret
  in
  (label, params)
