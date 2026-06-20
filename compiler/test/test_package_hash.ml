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

let write_package root ?(exports = [ "sample" ]) ~file_rel ~contents () =
  let src = Filename.concat root "src" in
  ensure_dir src;
  write_file
    (Filename.concat root "package.toml")
    (Printf.sprintf
       "[package]\n\
        name = \"sample\"\n\n\
        [compat]\n\
        std = \"preview-1\"\n\n\
        [exports]\n\
        modules = [%s]\n"
       (String.concat ", " (List.map (Printf.sprintf "%S") exports)));
  let file_path = Filename.concat src file_rel in
  ensure_dir (Filename.dirname file_path);
  write_file file_path contents

let package_hash root =
  match Blorp.Package_check.check root with
  | Error errors ->
      Alcotest.failf "package check failed:\n%s"
        (Blorp.Package_check.render_errors errors)
  | Ok checked -> (
      match
        Blorp.Package_hash.hash_checked_package ~root
          ~source_files:checked.Blorp.Package_check.source_files
      with
      | Ok hash -> hash
      | Error errors ->
          Alcotest.failf "package hash failed:\n%s"
            (Blorp.Package_hash.render_errors errors))

let test_hash_is_independent_of_root_path () =
  with_temp_dir "blorp_pkg_hash_a" (fun left ->
      with_temp_dir "blorp_pkg_hash_b" (fun right ->
          write_package left ~file_rel:"sample.brp"
            ~contents:"pure func answer() -> Int:\n    1\n" ();
          write_package right ~file_rel:"sample.brp"
            ~contents:"pure func answer() -> Int:\n    1\n" ();
          Alcotest.(check string)
            "same package content" (package_hash left) (package_hash right)))

let test_hash_changes_when_content_changes () =
  with_temp_dir "blorp_pkg_hash_content" (fun root ->
      write_package root ~file_rel:"sample.brp"
        ~contents:"pure func answer() -> Int:\n    1\n" ();
      let first = package_hash root in
      write_package root ~file_rel:"sample.brp"
        ~contents:"pure func answer() -> Int:\n    2\n" ();
      let second = package_hash root in
      Alcotest.(check bool) "content changes hash" true (first <> second))

let test_hash_changes_when_path_changes () =
  with_temp_dir "blorp_pkg_hash_path_a" (fun left ->
      with_temp_dir "blorp_pkg_hash_path_b" (fun right ->
          write_package left ~file_rel:"sample.brp"
            ~contents:"pure func answer() -> Int:\n    1\n" ();
          write_package right ~exports:[ "sample/nested" ]
            ~file_rel:"sample/nested.brp"
            ~contents:"pure func answer() -> Int:\n    1\n" ();
          Alcotest.(check bool)
            "path changes hash" true
            (package_hash left <> package_hash right)))

let test_hash_pin_normalization_accepts_uppercase_prefix () =
  match
    Blorp.Package_hash.validate_hash_pin
      "BLAKE3:ABCDEF0123456789ABCDEF0123456789"
  with
  | Error message ->
      Alcotest.failf "uppercase BLAKE3 pin was rejected: %s" message
  | Ok normalized ->
      Alcotest.(check string)
        "normalized pin" "abcdef0123456789abcdef0123456789" normalized

let suite =
  [
    ( "content address",
      [
        Alcotest.test_case "independent of root path" `Quick
          test_hash_is_independent_of_root_path;
        Alcotest.test_case "changes with content" `Quick
          test_hash_changes_when_content_changes;
        Alcotest.test_case "changes with path" `Quick
          test_hash_changes_when_path_changes;
        Alcotest.test_case "normalizes uppercase blake3 prefix" `Quick
          test_hash_pin_normalization_accepts_uppercase_prefix;
      ] );
  ]
