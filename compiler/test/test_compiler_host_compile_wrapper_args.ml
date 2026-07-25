open Blorp

let test_default_compile_request () =
  match
    Compiler_host_compile_wrapper_args.parse
      [ "-o"; "/tmp/output.c"; "source.brp" ]
  with
  | Ok request ->
      Alcotest.(check bool) "profile disabled" false request.profile;
      Alcotest.(check string) "output" "/tmp/output.c" request.output;
      Alcotest.(check string) "filename" "source.brp" request.filename
  | Error message -> Alcotest.fail message

let test_profiled_compile_request () =
  match
    Compiler_host_compile_wrapper_args.parse
      [ "--profile"; "-o"; "/tmp/output.c"; "source.brp" ]
  with
  | Ok request ->
      Alcotest.(check bool) "profile enabled" true request.profile;
      Alcotest.(check string) "output" "/tmp/output.c" request.output;
      Alcotest.(check string) "filename" "source.brp" request.filename
  | Error message -> Alcotest.fail message

let test_invalid_compile_request () =
  match Compiler_host_compile_wrapper_args.parse [ "--profile"; "source.brp" ] with
  | Ok _ -> Alcotest.fail "invalid wrapper arguments were accepted"
  | Error message ->
      Alcotest.(check bool)
        "usage names optional profile switch" true
        (Test_helpers.contains_substring message "[--profile]")

let suite =
  [
    ( "parse",
      [
        Alcotest.test_case "default compile request" `Quick
          test_default_compile_request;
        Alcotest.test_case "profiled compile request" `Quick
          test_profiled_compile_request;
        Alcotest.test_case "invalid compile request" `Quick
          test_invalid_compile_request;
      ] );
  ]
