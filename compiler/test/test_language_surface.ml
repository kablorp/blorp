open Blorp

let test_facade_uses_generated_language_surface_data () =
  Alcotest.(check (list string))
    "completion keywords"
    Language_surface_data.lsp_completion_keywords
    (Language_surface.lsp_completion_keywords ());
  Alcotest.(check (list (pair string string)))
    "prelude method type imports"
    Language_surface_data.prelude_method_type_imports
    (Language_surface.prelude_method_type_imports ());
  Alcotest.(check (list string))
    "prelude UFCS modules"
    Language_surface_data.prelude_ufcs_modules
    (Language_surface.prelude_ufcs_modules ())

let test_completion_keywords_do_not_advertise_removed_syntax () =
  let keywords = Language_surface.lsp_completion_keywords () in
  Alcotest.(check bool) "export absent" false (List.mem "export" keywords);
  Alcotest.(check bool) "try absent" false (List.mem "try" keywords)

let test_generated_language_surface_contains_required_prelude_methods () =
  let keywords = Language_surface_data.lsp_completion_keywords in
  let method_imports = Language_surface_data.prelude_method_type_imports in
  let ufcs_modules = Language_surface_data.prelude_ufcs_modules in
  Alcotest.(check bool) "keywords generated" true (List.mem "func" keywords);
  Alcotest.(check bool)
    "parallel list method import generated" true
    (List.mem ("parallel_list", "ParallelList") method_imports);
  Alcotest.(check bool)
    "parallel vector method import generated" true
    (List.mem ("parallel_vector", "ParallelVector") method_imports);
  Alcotest.(check bool)
    "parallel matrix method import generated" true
    (List.mem ("parallel_matrix", "ParallelMatrix") method_imports);
  Alcotest.(check bool) "parallel list UFCS module generated" true
    (List.mem "parallel_list" ufcs_modules);
  Alcotest.(check bool) "parallel vector UFCS module generated" true
    (List.mem "parallel_vector" ufcs_modules);
  Alcotest.(check bool) "parallel matrix UFCS module generated" true
    (List.mem "parallel_matrix" ufcs_modules)

let test_renderer_helper_uses_generated_language_surface_rows () =
  let requested =
    List.map (fun (name, _row) -> (name, [])) Language_surface_data.rows
  in
  let rendered =
    Compiler_blorp_bridge.render_many_for_renderer_helper_exn
      ~renderer:Compiler_blorp_bridge.language_surface_renderer requested
  in
  Alcotest.(check (list (pair string string)))
    "language surface renderer rows" Language_surface_data.rows rendered

let suite =
  [
    ( "data",
      [
        Alcotest.test_case "facade uses generated language surface data" `Quick
          test_facade_uses_generated_language_surface_data;
        Alcotest.test_case
          "completion keywords do not advertise removed syntax" `Quick
          test_completion_keywords_do_not_advertise_removed_syntax;
        Alcotest.test_case
          "generated language surface contains required prelude methods" `Quick
          test_generated_language_surface_contains_required_prelude_methods;
        Alcotest.test_case
          "renderer helper uses generated language surface rows" `Quick
          test_renderer_helper_uses_generated_language_surface_rows;
      ] );
  ]
