let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let rec remove_tree path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Array.iter
          (fun name -> remove_tree (Filename.concat path name))
          (Sys.readdir path);
        Unix.rmdir path
      end
      else Sys.remove path
  in
  Fun.protect
    ~finally:(fun () -> try remove_tree dir with _ -> ())
    (fun () -> f dir)

let ensure_dir path = if not (Sys.file_exists path) then Unix.mkdir path 0o700

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let write_package_manifest root ?(std = "preview-1") ?(modules = [ "sample" ])
    () =
  write_file
    (Filename.concat root "package.toml")
    (Printf.sprintf
       {|
[package]
name = "sample"

[compat]
std = "%s"

[exports]
modules = [%s]
|}
       std
       (String.concat ", " (List.map (Printf.sprintf "%S") modules)))

let with_package f =
  with_temp_dir "blorp_package_check" (fun root ->
      let src = Filename.concat root "src" in
      ensure_dir src;
      f root src)

let expect_ok root =
  match Blorp.Package_check.check root with
  | Ok result -> result
  | Error errors ->
      Alcotest.failf "expected package check to pass, got:\n%s"
        (Blorp.Package_check.render_errors errors)

let expect_error root expected =
  match Blorp.Package_check.check root with
  | Ok _ -> Alcotest.fail "expected package check error"
  | Error errors ->
      let text = Blorp.Package_check.render_errors errors in
      Alcotest.(check bool)
        ("contains " ^ expected) true
        (Blorp.Modules.contains text expected)

let test_accepts_source_package () =
  with_package (fun root src ->
      write_package_manifest root ~modules:[ "sample"; "sample/internal" ] ();
      ensure_dir (Filename.concat src "sample");
      write_file
        (Filename.concat src "sample.brp")
        "import:\n\
        \    sample/internal as Internal\n\n\
         pure func answer() -> Int:\n\
        \    Internal.answer()\n";
      write_file
        (Filename.concat (Filename.concat src "sample") "internal.brp")
        "pure func answer() -> Int:\n    42\n";
      let result = expect_ok root in
      Alcotest.(check int)
        "source file count" 2
        (List.length result.Blorp.Package_check.source_files))

let test_accepts_relative_import_under_src () =
  with_package (fun root src ->
      write_package_manifest root ~modules:[ "sample" ] ();
      write_file
        (Filename.concat src "sample.brp")
        "import:\n\
        \    ./helper as Helper\n\n\
         pure func answer() -> Int:\n\
        \    Helper.answer()\n";
      write_file
        (Filename.concat src "helper.brp")
        "pure func answer() -> Int:\n    1\n";
      ignore (expect_ok root))

let test_rejects_missing_export () =
  with_package (fun root _src ->
      write_package_manifest root ~modules:[ "sample" ] ();
      expect_error root "exported module \"sample\" does not exist")

let test_rejects_external_import () =
  with_package (fun root src ->
      write_package_manifest root ~modules:[ "sample" ] ();
      write_file
        (Filename.concat src "sample.brp")
        "import:\n    local_helper\n\npure func answer() -> Int:\n    0\n";
      expect_error root "may import only std modules")

let test_rejects_foreign () =
  with_package (fun root src ->
      write_package_manifest root ~modules:[ "sample" ] ();
      write_file
        (Filename.concat src "sample.brp")
        "foreign(include: \"math.h\"):\n\
        \    func c_abs(x: Int) -> Int = \"abs\"\n";
      expect_error root "'foreign' declarations are not allowed")

let test_rejects_builtin_body () =
  with_package (fun root src ->
      write_package_manifest root ~modules:[ "sample" ] ();
      write_file
        (Filename.concat src "sample.brp")
        "func compiler_owned(x: Int) -> Int:\n    builtin\n";
      expect_error root "'builtin' function bodies are not allowed")

let test_rejects_builtin_type () =
  with_package (fun root src ->
      write_package_manifest root ~modules:[ "sample" ] ();
      write_file (Filename.concat src "sample.brp") "type Sample = builtin\n";
      expect_error root "'builtin' types are not allowed")

let test_rejects_std_compat_mismatch () =
  with_package (fun root src ->
      write_package_manifest root ~std:"future-99" ~modules:[ "sample" ] ();
      write_file
        (Filename.concat src "sample.brp")
        "pure func answer() -> Int:\n    0\n";
      expect_error root "this compiler supports")

let test_rejects_type_error () =
  with_package (fun root src ->
      write_package_manifest root ~modules:[ "sample" ] ();
      write_file
        (Filename.concat src "sample.brp")
        "pure func answer() -> Int:\n    \"not an int\"\n";
      expect_error root "returns wrong type")

let suite =
  [
    ( "source package policy",
      [
        Alcotest.test_case "accepts valid source package" `Quick
          test_accepts_source_package;
        Alcotest.test_case "accepts relative import under src" `Quick
          test_accepts_relative_import_under_src;
        Alcotest.test_case "rejects missing export" `Quick
          test_rejects_missing_export;
        Alcotest.test_case "rejects external import" `Quick
          test_rejects_external_import;
        Alcotest.test_case "rejects foreign" `Quick test_rejects_foreign;
        Alcotest.test_case "rejects builtin body" `Quick
          test_rejects_builtin_body;
        Alcotest.test_case "rejects builtin type" `Quick
          test_rejects_builtin_type;
        Alcotest.test_case "rejects std compat mismatch" `Quick
          test_rejects_std_compat_mismatch;
        Alcotest.test_case "rejects type error" `Quick test_rejects_type_error;
      ] );
  ]
