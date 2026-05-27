(** LSP server — main event loop and request/notification dispatch.

    Handles the LSP lifecycle (initialize/shutdown/exit) and dispatches
    document events to the analysis pipeline. *)

open Lsp_json
open Lsp_rpc
open Lsp_protocol

(* ============================================================================
   Handlers
   ============================================================================ *)

(** Handle initialize request *)
let handle_initialize (state : Lsp_state.state) _params =
  state.initialized <- true;
  Object
    [
      ("capabilities", capabilities);
      ( "serverInfo",
        Object [ ("name", String "blorp"); ("version", String Version.version) ]
      );
    ]

(** Publish diagnostics for a document *)
let publish_diagnostics oc (doc : Lsp_state.document) =
  let params = Lsp_state.get_diagnostics_json doc in
  send_notification oc ~method_:"textDocument/publishDiagnostics" ~params

let text_document_version td =
  match get_int "version" td with Some v -> v | None -> 0

let latest_content_change_text params ~default =
  match get_list "contentChanges" params with
  | Some changes -> (
      match List.rev changes with
      | last :: _ -> (
          match get_string "text" last with Some t -> t | None -> default)
      | [] -> default)
  | None -> default

let make_document ~uri ~version ~text : Lsp_state.document =
  {
    uri;
    version;
    text;
    diagnostics = [];
    parse_errors = [];
    program = None;
    typed_program = None;
    env = None;
    module_aliases = [];
  }

let store_analyzed_document state oc doc =
  Hashtbl.replace state.Lsp_state.documents doc.Lsp_state.uri doc;
  Lsp_state.analyze state doc;
  publish_diagnostics oc doc

(** Handle textDocument/didOpen *)
let handle_did_open (state : Lsp_state.state) oc params =
  match get "textDocument" params with
  | Some td ->
      let uri = get_uri td in
      let version = text_document_version td in
      let text = match get_string "text" td with Some t -> t | None -> "" in
      make_document ~uri ~version ~text |> store_analyzed_document state oc
  | None -> ()

(** Handle textDocument/didChange *)
let handle_did_change (state : Lsp_state.state) oc params =
  match get "textDocument" params with
  | Some td -> (
      let uri = get_uri td in
      let version = text_document_version td in
      match Lsp_state.find_document state uri with
      | Some doc ->
          (* Full sync: take the last content change *)
          let text = latest_content_change_text params ~default:doc.text in
          let doc : Lsp_state.document = { doc with version; text } in
          store_analyzed_document state oc doc
      | None ->
          let text = latest_content_change_text params ~default:"" in
          make_document ~uri ~version ~text |> store_analyzed_document state oc)
  | None -> ()

(** Handle textDocument/didSave *)
let handle_did_save (state : Lsp_state.state) oc params =
  match get "textDocument" params with
  | Some td -> (
      let uri = get_uri td in
      (* Use included text if available, otherwise re-analyze existing *)
      let text = get_string "text" params in
      match Lsp_state.find_document state uri with
      | Some doc ->
          let doc =
            match text with Some t -> { doc with text = t } | None -> doc
          in
          store_analyzed_document state oc doc
      | None -> ())
  | None -> ()

(** Handle textDocument/didClose *)
let handle_did_close (state : Lsp_state.state) oc params =
  match get "textDocument" params with
  | Some td ->
      let uri = get_uri td in
      Hashtbl.remove state.documents uri;
      (* Clear diagnostics *)
      send_notification oc ~method_:"textDocument/publishDiagnostics"
        ~params:(Lsp_protocol.publish_diagnostics ~uri ~diagnostics:[])
  | None -> ()

(** Handle textDocument/hover *)
let handle_hover (state : Lsp_state.state) params =
  let td = get "textDocument" params in
  let pos = get "position" params in
  match (td, pos) with
  | Some td, Some pos_json -> (
      let uri = get_uri td in
      let position = position_of_json pos_json in
      match (Lsp_state.find_document state uri, position) with
      | Some doc, Some pos -> (
          let file = Lsp_protocol.uri_to_path uri in
          (* Try expression lookup first *)
          let expr_hover =
            match (doc.program, doc.env) with
            | Some program, Some env -> (
                match
                  Lsp_position.find_expr_at program ~line:pos.line
                    ~col:pos.character
                with
                | Some expr -> Lsp_hover.hover_info_for_expr env expr
                | None -> None)
            | _ -> None
          in
          (* Fall back to declaration lookup *)
          let hover =
            match expr_hover with
            | Some _ -> expr_hover
            | None -> (
                let typed_param_hover =
                  match doc.typed_program with
                  | Some typed_program -> (
                      match
                        Lsp_position.find_typed_param_at typed_program ~file
                          ~line:pos.line ~col:pos.character
                      with
                      | Some hit ->
                          Some
                            (Lsp_hover.hover_info_for_typed_param
                               ~name:hit.Lsp_position.param_name
                               ~source_ty:hit.source_param_ty
                               ~semantic_ty:hit.semantic_param_ty)
                      | None -> None)
                  | None -> None
                in
                match typed_param_hover with
                | Some _ -> typed_param_hover
                | None -> (
                    let typed_decl_hover =
                      match doc.typed_program with
                      | Some typed_program -> (
                          match
                            Lsp_position.find_typed_decl_at typed_program ~file
                              ~line:pos.line
                          with
                          | Some d -> Lsp_hover.hover_info_for_typed_decl d
                          | None -> None)
                      | None -> None
                    in
                    match typed_decl_hover with
                    | Some _ -> typed_decl_hover
                    | None -> (
                        match doc.program with
                        | Some program -> (
                            match
                              Lsp_position.find_decl_at program ~line:pos.line
                                ~file
                            with
                            | Some d -> Lsp_hover.hover_info_for_decl d
                            | None -> None)
                        | None -> None)))
          in
          match hover with
          | Some contents ->
              let range =
                {
                  start = { line = pos.line; character = pos.character };
                  end_ = { line = pos.line; character = pos.character + 1 };
                }
              in
              hover_response ~contents ~range
          | None -> Null)
      | _ -> Null)
  | _ -> Null

(** Handle textDocument/definition *)
let handle_definition (state : Lsp_state.state) params =
  let td = get "textDocument" params in
  let pos = get "position" params in
  match (td, pos) with
  | Some td, Some pos_json -> (
      let uri = get_uri td in
      let position = position_of_json pos_json in
      match (Lsp_state.find_document state uri, position) with
      | Some doc, Some pos -> (
          (* Identify the word under the cursor from the raw text — this covers
              identifiers that aren't EIdent nodes (type annotations, pattern
              constructors, field names, etc.). *)
          match doc.program with
          | Some program -> (
              let name_opt =
                Lsp_position.word_at doc.text ~line:pos.line ~col:pos.character
              in
              match name_opt with
              | Some name -> (
                  let make_location target_uri def_loc =
                    let def_pos = Lsp_protocol.loc_to_position def_loc in
                    let range =
                      {
                        start = def_pos;
                        end_ =
                          {
                            def_pos with
                            character = def_pos.character + String.length name;
                          };
                      }
                    in
                    Lsp_protocol.location_json ~uri:target_uri ~range
                  in
                  match
                    Lsp_position.find_definition program ~name ~line:pos.line
                      ~col:pos.character
                  with
                  | Some def_loc -> make_location uri def_loc
                  | None -> (
                      (* Fall back to imported / prelude modules. Embedded
                             std paths get remapped to the on-disk std/ dir if
                             one is reachable from the open document. *)
                      match
                        Lsp_position.find_cross_module_definition program ~name
                      with
                      | Some (path, def_loc) ->
                          let base_dir =
                            Filename.dirname (Lsp_protocol.uri_to_path uri)
                          in
                          let real_path =
                            Lsp_position.resolve_module_source_path ~base_dir
                              path
                          in
                          make_location
                            (Lsp_protocol.path_to_uri real_path)
                            def_loc
                      | None -> Null))
              | None -> Null)
          | None -> Null)
      | _ -> Null)
  | _ -> Null

(** Handle textDocument/declaration.
    JetBrains exposes its primary navigation action as "Go to Declaration",
    while Blorp has a single source definition for each symbol today. *)
let handle_declaration = handle_definition

(** Handle textDocument/formatting *)
let handle_formatting (state : Lsp_state.state) params =
  match get "textDocument" params with
  | Some td -> (
      let uri = get_uri td in
      match Lsp_state.find_document state uri with
      | Some doc -> (
          match Fmt.format_string doc.text with
          | Ok formatted ->
              if formatted = doc.text then Array []
              else Array [ full_document_edit formatted ]
          | Error _ -> Array [])
      | None -> Array [])
  | None -> Array []

(* ============================================================================
   Main event loop
   ============================================================================ *)

(** Run the LSP server on stdin/stdout *)
let rec run () =
  let ic = stdin in
  let oc = stdout in
  let state = Lsp_state.create () in
  let shutdown_requested = ref false in

  log "blorp LSP server starting";

  let rec loop () =
    match read_message ic with
    | None ->
        log "connection closed";
        exit 0
    | Some msg ->
        (try dispatch state ic oc msg shutdown_requested
         with exn -> (
           log "error handling %s: %s" msg.method_ (Printexc.to_string exn);
           (* Send error response if it was a request *)
           match msg.id with
           | Some id ->
               send_error oc ~id ~code:(-32603)
                 ~message:
                   (Printf.sprintf "Internal error: %s" (Printexc.to_string exn))
           | None -> ()));
        loop ()
  in
  loop ()

and dispatch state _ic oc (msg : message) shutdown_requested =
  match msg.method_ with
  | "initialize" -> (
      match msg.id with
      | Some id ->
          let result = handle_initialize state msg.params in
          send_response oc ~id ~result
      | None -> ())
  | "initialized" -> log "client initialized"
  | "shutdown" -> (
      shutdown_requested := true;
      match msg.id with
      | Some id -> send_response oc ~id ~result:Null
      | None -> ())
  | "exit" ->
      log "exit";
      exit (if !shutdown_requested then 0 else 1)
  | "textDocument/didOpen" -> handle_did_open state oc msg.params
  | "textDocument/didChange" -> handle_did_change state oc msg.params
  | "textDocument/didSave" -> handle_did_save state oc msg.params
  | "textDocument/didClose" -> handle_did_close state oc msg.params
  | "textDocument/hover" -> (
      match msg.id with
      | Some id ->
          let result = handle_hover state msg.params in
          send_response oc ~id ~result
      | None -> ())
  | "textDocument/definition" -> (
      match msg.id with
      | Some id ->
          let result = handle_definition state msg.params in
          send_response oc ~id ~result
      | None -> ())
  | "textDocument/declaration" -> (
      match msg.id with
      | Some id ->
          let result = handle_declaration state msg.params in
          send_response oc ~id ~result
      | None -> ())
  | "textDocument/formatting" -> (
      match msg.id with
      | Some id ->
          let result = handle_formatting state msg.params in
          send_response oc ~id ~result
      | None -> ())
  | "textDocument/completion" -> (
      match msg.id with
      | Some id ->
          let result = Lsp_completion.handle_completion state msg.params in
          send_response oc ~id ~result
      | None -> ())
  | "textDocument/documentSymbol" -> (
      match msg.id with
      | Some id ->
          let result = Lsp_symbols.handle_document_symbols state msg.params in
          send_response oc ~id ~result
      | None -> ())
  | "textDocument/signatureHelp" -> (
      match msg.id with
      | Some id ->
          let result = Lsp_signature.handle_signature_help state msg.params in
          send_response oc ~id ~result
      | None -> ())
  | method_ -> (
      log "unhandled method: %s" method_;
      (* For requests we don't handle, send MethodNotFound error *)
      match msg.id with
      | Some id ->
          send_error oc ~id ~code:(-32601)
            ~message:("Method not found: " ^ method_)
      | None -> ())
