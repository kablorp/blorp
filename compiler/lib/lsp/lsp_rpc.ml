(** JSON-RPC 2.0 transport over stdio with Content-Length framing.

    Reads/writes LSP messages on stdin/stdout with proper
    Content-Length headers. Logging goes to stderr. *)

open Lsp_json

type message = {
  id : json option;  (** Request id (Int or String), None for notifications *)
  method_ : string;  (** Method name *)
  params : json;  (** Parameters (Object or Array) *)
}
(** A parsed JSON-RPC message *)

(** Log a message to stderr (never to stdout — that's the LSP channel) *)
let log fmt =
  Printf.ksprintf (fun s -> Printf.eprintf "[blorp-lsp] %s\n%!" s) fmt

(* ============================================================================
   Reading messages
   ============================================================================ *)

(** Read Content-Length header, return the content length.
    Returns None on EOF. *)
let read_headers ic =
  let content_length = ref None in
  let rec loop () =
    let line = try Some (input_line ic) with End_of_file -> None in
    match line with
    | None -> None
    | Some line ->
        (* Strip \r if present *)
        let line =
          if String.length line > 0 && line.[String.length line - 1] = '\r' then
            String.sub line 0 (String.length line - 1)
          else line
        in
        if line = "" then
          (* Empty line = end of headers *)
          !content_length
        else begin
          (* Parse Content-Length header *)
          let prefix = "Content-Length: " in
          let prefix_len = String.length prefix in
          if
            String.length line >= prefix_len
            && String.sub line 0 prefix_len = prefix
          then begin
            let len_str =
              String.sub line prefix_len (String.length line - prefix_len)
            in
            try content_length := Some (int_of_string len_str) with _ -> ()
          end;
          loop ()
        end
  in
  loop ()

(** Read a single JSON-RPC message from the input channel.
    Returns None on EOF. *)
let read_message ic =
  match read_headers ic with
  | None -> None
  | Some content_length ->
      if content_length <= 0 || content_length > 10_000_000 then
        None (* Invalid content length — skip this message *)
      else begin
        let buf = Bytes.create content_length in
        really_input ic buf 0 content_length;
        let body = Bytes.to_string buf in
        let json = parse body in
        let id = get "id" json in
        let method_ =
          match get_string "method" json with Some m -> m | None -> ""
        in
        let params =
          match get "params" json with Some p -> p | None -> Object []
        in
        Some { id; method_; params }
      end

(* ============================================================================
   Writing messages
   ============================================================================ *)

(** Write a JSON payload with Content-Length header to stdout *)
let write_message oc json =
  let body = to_string json in
  let header =
    Printf.sprintf "Content-Length: %d\r\n\r\n" (String.length body)
  in
  output_string oc header;
  output_string oc body;
  flush oc

(** Send a JSON-RPC response (for requests with an id) *)
let send_response oc ~id ~result =
  write_message oc
    (Object [ ("jsonrpc", String "2.0"); ("id", id); ("result", result) ])

(** Send a JSON-RPC error response *)
let send_error oc ~id ~code ~message =
  write_message oc
    (Object
       [
         ("jsonrpc", String "2.0");
         ("id", id);
         ("error", Object [ ("code", Int code); ("message", String message) ]);
       ])

(** Send a JSON-RPC notification (no id, no response expected) *)
let send_notification oc ~method_ ~params =
  write_message oc
    (Object
       [
         ("jsonrpc", String "2.0");
         ("method", String method_);
         ("params", params);
       ])
