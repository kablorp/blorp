let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let test_renderer_bridge_binary_uses_content_cache () =
  Blorp.Compiler_test_runner.with_temp_dir "blorp-renderer-bridge-cache-"
    (fun dir ->
      let cache_dir = Filename.concat dir "cache" in
      let source_path = Filename.concat dir "compiler_bridge_cli.brp" in
      let fake_program = Filename.concat dir "fake-blorp" in
      let call_log = Filename.concat dir "calls.log" in
      Blorp.Compiler_test_runner.write_file source_path
        "func main(args: List[String]) -> Int: 0\n";
      Blorp.Compiler_test_runner.write_file fake_program
        (String.concat "\n"
           [
             "#!/bin/sh";
             "echo call >> " ^ Filename.quote call_log;
             "out=''";
             "while [ \"$#\" -gt 0 ]; do";
             "  if [ \"$1\" = '-o' ]; then";
             "    shift";
             "    out=\"$1\"";
             "  fi";
             "  shift";
             "done";
             "cat > \"$out\" <<'C'";
             "#include <stdio.h>";
             "int main(int argc, char** argv) {";
             "  (void)argc;";
             "  (void)argv;";
             "  puts(\"{\\\"schema\\\":1,\\\"ok\\\":true}\");";
             "  return 0;";
             "}";
             "C";
             "";
           ]);
      Unix.chmod fake_program 0o700;
      with_env "BLORP_COMPILER_BRIDGE_CACHE_DIR" cache_dir (fun () ->
          with_env "BLORP_COMPILER_BRIDGE_RENDERER_SOURCE" source_path
            (fun () ->
              let clear_process_cache =
                Blorp.Compiler_blorp_bridge
                .clear_renderer_bridge_process_cache_for_test
              in
              clear_process_cache ();
              let first =
                Blorp.Compiler_blorp_bridge.renderer_bridge_binary
                  ~program:fake_program ()
              in
              clear_process_cache ();
              let second =
                Blorp.Compiler_blorp_bridge.renderer_bridge_binary
                  ~program:fake_program ()
              in
              match (first, second) with
              | Ok first_path, Ok second_path ->
                  Alcotest.(check string)
                    "cached bridge path is stable" first_path second_path;
                  Alcotest.(check bool)
                    "cached bridge binary exists" true
                    (Sys.file_exists second_path);
                  Alcotest.(check bool)
                    "generated C is not persisted in cache" false
                    (Sys.file_exists
                       (Filename.concat
                          (Filename.dirname second_path)
                          "bridge.c"));
                  Alcotest.(check string)
                    "fake compiler invoked once" "call\n"
                    (Blorp.Compiler_test_runner.read_file call_log)
              | Error message, _ | _, Error message -> Alcotest.fail message)))

let suite =
  [
    ( "compiler_blorp_tests",
      [
        Alcotest.test_case "renderer bridge binary uses content cache" `Quick
          test_renderer_bridge_binary_uses_content_cache;
      ] );
  ]
