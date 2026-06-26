let contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if needle_len = 0 then true
    else if index + needle_len > haystack_len then false
    else if String.sub haystack index needle_len = needle then true
    else loop (index + 1)
  in
  loop 0

let test_renderer_bridge_compile_renames_generated_main () =
  let args =
    Blorp.Compiler_blorp_bridge.renderer_bridge_compile_object_args
      ~c_path:"bridge.c" ~obj_path:"bridge.o"
  in
  Alcotest.(check bool)
    "generated bridge main is renamed" true
    (List.exists
       (( = )
          ("-Dmain=" ^ Blorp.Compiler_blorp_bridge.renderer_bridge_user_main_symbol))
       args);
  Alcotest.(check bool) "compiles to object" true (List.exists (( = ) "-c") args)

let test_renderer_bridge_link_uses_wrapper_main () =
  let args =
    Blorp.Compiler_blorp_bridge.renderer_bridge_link_args ~obj_path:"bridge.o"
      ~wrapper_path:"bridge_main.c" ~bin_path:"bridge.bin"
  in
  Alcotest.(check bool)
    "links generated object" true
    (List.exists (( = ) "bridge.o") args);
  Alcotest.(check bool)
    "links wrapper source" true
    (List.exists (( = ) "bridge_main.c") args);
  Alcotest.(check bool)
    "links pthread for stack wrapper" true
    (List.exists (( = ) "-lpthread") args)

let test_renderer_bridge_wrapper_sets_explicit_stack () =
  let source = Blorp.Compiler_blorp_bridge.renderer_bridge_wrapper_source () in
  Alcotest.(check bool)
    "sets pthread stack size" true
    (contains source "pthread_attr_setstacksize");
  Alcotest.(check bool)
    "uses configured stack size" true
    (contains source
       (string_of_int
          Blorp.Compiler_blorp_bridge.renderer_bridge_stack_size_bytes));
  Alcotest.(check bool)
    "calls renamed generated entrypoint" true
    (contains source Blorp.Compiler_blorp_bridge.renderer_bridge_user_main_symbol)

let suite =
  [
    ( "renderer_bridge_build",
      [
        Alcotest.test_case "renames generated main" `Quick
          test_renderer_bridge_compile_renames_generated_main;
        Alcotest.test_case "links wrapper main" `Quick
          test_renderer_bridge_link_uses_wrapper_main;
        Alcotest.test_case "wrapper sets explicit stack" `Quick
          test_renderer_bridge_wrapper_sets_explicit_stack;
      ] );
  ]
