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

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let artifact_entry rel_path contents : Blorp.Package_hash.entry =
  { rel_path; contents }

let write_artifact path entries =
  write_file path (Blorp.Package_artifact.artifact_bytes entries)

let expect_read_error artifact expected =
  match Blorp.Package_artifact.read artifact with
  | Ok _ -> Alcotest.fail "expected artifact read to fail"
  | Error errors ->
      let text = Blorp.Package_artifact.render_errors errors in
      Alcotest.(check bool)
        ("contains " ^ expected) true
        (Blorp.Modules.contains text expected)

let test_read_rejects_unsafe_path () =
  with_temp_dir "blorp_package_artifact_unsafe" (fun dir ->
      let artifact = Filename.concat dir "bad.blorpkg" in
      write_artifact artifact [ artifact_entry "../escape.brp" "bad" ];
      expect_read_error artifact "unsafe path")

let test_read_rejects_duplicate_path () =
  with_temp_dir "blorp_package_artifact_duplicate" (fun dir ->
      let artifact = Filename.concat dir "bad.blorpkg" in
      write_artifact artifact
        [
          artifact_entry "package.toml" "one";
          artifact_entry "package.toml" "two";
        ];
      expect_read_error artifact "duplicate path")

let test_read_rejects_oversized_length () =
  with_temp_dir "blorp_package_artifact_length" (fun dir ->
      let artifact = Filename.concat dir "bad.blorpkg" in
      write_file artifact
        ("blorp-package-artifact-v1\000file\000" ^ string_of_int max_int
       ^ "0\000");
      expect_read_error artifact "artifact length is too large")

let test_unpack_rejects_unsafe_path_without_writing () =
  with_temp_dir "blorp_package_artifact_unpack" (fun dir ->
      let target = Filename.concat dir "target" in
      let escaped = Filename.concat dir "escape.brp" in
      match
        Blorp.Package_artifact.unpack_entries ~target
          [ artifact_entry "../escape.brp" "bad" ]
      with
      | Ok () -> Alcotest.fail "expected unsafe unpack path to fail"
      | Error errors ->
          let text = Blorp.Package_artifact.render_errors errors in
          Alcotest.(check bool)
            "unsafe path message" true
            (Blorp.Modules.contains text "unsafe path");
          Alcotest.(check bool)
            "escaped file was not written" false (Sys.file_exists escaped))

let test_unpack_rejects_duplicate_path_before_writing () =
  with_temp_dir "blorp_package_artifact_unpack_duplicate" (fun dir ->
      let target = Filename.concat dir "target" in
      let package_toml = Filename.concat target "package.toml" in
      match
        Blorp.Package_artifact.unpack_entries ~target
          [
            artifact_entry "package.toml" "one";
            artifact_entry "package.toml" "two";
          ]
      with
      | Ok () -> Alcotest.fail "expected duplicate unpack path to fail"
      | Error errors ->
          let text = Blorp.Package_artifact.render_errors errors in
          Alcotest.(check bool)
            "duplicate path message" true
            (Blorp.Modules.contains text "duplicate path");
          Alcotest.(check bool)
            "duplicate target was not written" false
            (Sys.file_exists package_toml))

let suite =
  [
    ( "artifact safety",
      [
        Alcotest.test_case "read rejects unsafe path" `Quick
          test_read_rejects_unsafe_path;
        Alcotest.test_case "read rejects duplicate path" `Quick
          test_read_rejects_duplicate_path;
        Alcotest.test_case "read rejects oversized length" `Quick
          test_read_rejects_oversized_length;
        Alcotest.test_case "unpack rejects unsafe path without writing" `Quick
          test_unpack_rejects_unsafe_path_without_writing;
        Alcotest.test_case "unpack rejects duplicate path before writing" `Quick
          test_unpack_rejects_duplicate_path_before_writing;
      ] );
  ]
