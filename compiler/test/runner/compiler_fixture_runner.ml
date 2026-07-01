let command_line_args () =
  match Array.to_list Sys.argv with _ :: args -> args | [] -> []

let () =
  exit
    (Blorp_compiler_fixture_runner.Compiler_test_runner.run_cli
       (command_line_args ()))
