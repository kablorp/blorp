open Blorp

let fail message =
  prerr_endline ("blorp semantic-middle worker: " ^ message);
  exit 2

let () =
  if Array.length Sys.argv <> 1 then
    fail "this private worker accepts requests on stdin and has no CLI flags";
  let request_text = In_channel.input_all stdin in
  let request_json =
    try Lsp_json.parse request_text
    with Lsp_json.Parse_error message -> fail ("invalid JSON: " ^ message)
  in
  let request =
    match Semantic_middle_worker.decode_request request_json with
    | Ok request -> request
    | Error error -> fail (error.code ^ ": " ^ error.message)
  in
  (try Semantic_middle_worker.run_request request
   with exn -> fail ("internal failure: " ^ Printexc.to_string exn))
  |> Semantic_middle_worker.response_json |> Lsp_json.to_string |> print_endline
