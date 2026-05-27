(** Unit tests for JSON-RPC framing used by the LSP server. *)

open Blorp

let with_temp_input contents f =
  let path = Filename.temp_file "blorp-lsp-rpc" ".txt" in
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents);
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () ->
      close_in_noerr ic;
      Sys.remove path)
    (fun () -> f ic)

let framed ?(header = "Content-Length") body =
  Printf.sprintf "%s:%d\r\n\r\n%s" header (String.length body) body

let test_read_message_accepts_trimmed_content_length () =
  let body =
    {|{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"ok":true}}|}
  in
  with_temp_input (framed body) (fun ic ->
      match Lsp_rpc.read_message ic with
      | Some msg ->
          Alcotest.(check (option int))
            "id" (Some 3)
            (match msg.id with Some (Lsp_json.Int id) -> Some id | _ -> None);
          Alcotest.(check string) "method" "textDocument/hover" msg.method_;
          Alcotest.(check bool)
            "params object" true
            (match msg.params with Lsp_json.Object _ -> true | _ -> false)
      | None -> Alcotest.fail "expected framed message")

let test_read_message_accepts_case_insensitive_header_name () =
  let body = {|{"jsonrpc":"2.0","method":"initialized"}|} in
  with_temp_input (framed ~header:"content-length" body) (fun ic ->
      match Lsp_rpc.read_message ic with
      | Some msg ->
          Alcotest.(check string) "method" "initialized" msg.method_;
          Alcotest.(check (option string))
            "notification id" None
            (Option.map (fun _ -> "unexpected") msg.id)
      | None -> Alcotest.fail "expected framed message")

let suite =
  [
    ( "rpc",
      [
        Alcotest.test_case "read_message accepts trimmed Content-Length" `Quick
          test_read_message_accepts_trimmed_content_length;
        Alcotest.test_case "read_message accepts case-insensitive header" `Quick
          test_read_message_accepts_case_insensitive_header_name;
      ] );
  ]
