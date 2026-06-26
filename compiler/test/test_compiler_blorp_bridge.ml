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

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents)

let mkdir path = try Unix.mkdir path 0o700 with Unix.Unix_error _ -> ()

let with_temp_dir f =
  let root = Filename.temp_file "blorp-bridge-test-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () ->
      let rec remove path =
        match (Unix.lstat path).Unix.st_kind with
        | Unix.S_DIR ->
            Sys.readdir path
            |> Array.iter (fun name -> remove (Filename.concat path name));
            Unix.rmdir path
        | _ -> Sys.remove path
      in
      remove root)
    (fun () -> f root)

let test_renderer_bridge_default_prefers_pinned_bootstrap () =
  with_temp_dir (fun root ->
      let scripts_dir = Filename.concat root "scripts" in
      let nested_dir = Filename.concat root "nested" in
      let deeper_dir = Filename.concat nested_dir "deeper" in
      let bootstrap =
        Filename.concat scripts_dir "blorp-compiler-bootstrap"
      in
      mkdir scripts_dir;
      mkdir nested_dir;
      mkdir deeper_dir;
      write_file bootstrap "#!/usr/bin/env bash\n";
      match
        Blorp.Compiler_blorp_bridge.locate_default_command_program
          ~bridge_bin:None [ deeper_dir ]
      with
      | Some path -> Alcotest.(check string) "bootstrap path" bootstrap path
      | None -> Alcotest.fail "expected bootstrap command to be discovered")

let test_renderer_bridge_default_respects_explicit_override () =
  match
    Blorp.Compiler_blorp_bridge.locate_default_command_program
      ~bridge_bin:(Some "/tmp/custom-blorp") [ "/does/not/exist" ]
  with
  | Some path ->
      Alcotest.(check string) "explicit bridge binary" "/tmp/custom-blorp" path
  | None -> Alcotest.fail "expected explicit bridge binary to win"

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
        Alcotest.test_case "default uses pinned bootstrap" `Quick
          test_renderer_bridge_default_prefers_pinned_bootstrap;
        Alcotest.test_case "default respects explicit override" `Quick
          test_renderer_bridge_default_respects_explicit_override;
      ] );
  ]
