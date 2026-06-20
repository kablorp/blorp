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

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let ensure_dir path = if not (Sys.file_exists path) then Unix.mkdir path 0o700

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let write_package root =
  let src = Filename.concat root "src" in
  ensure_dir src;
  write_file
    (Filename.concat root "package.toml")
    "[package]\n\
     name = \"sample\"\n\n\
     [compat]\n\
     std = \"preview-1\"\n\n\
     [exports]\n\
     modules = [\"sample\"]\n";
  write_file
    (Filename.concat src "sample.brp")
    "pure func answer() -> Int:\n    42\n"

let checked_package root =
  match Blorp.Package_check.check root with
  | Ok checked -> checked
  | Error errors ->
      Alcotest.failf "package check failed:\n%s"
        (Blorp.Package_check.render_errors errors)

let pack_package ~root ~output =
  let checked = checked_package root in
  match
    Blorp.Package_artifact.write_checked_package ~root
      ~source_files:checked.Blorp.Package_check.source_files ~output
  with
  | Ok hash -> hash
  | Error errors ->
      Alcotest.failf "package pack failed:\n%s"
        (Blorp.Package_artifact.render_errors errors)

let test_fetch_installs_verified_cache_entry () =
  with_temp_dir "blorp_package_cache" (fun dir ->
      let package_dir = Filename.concat dir "package" in
      let cache_dir = Filename.concat dir "cache" in
      let artifact = Filename.concat dir "sample.blorpkg" in
      Unix.mkdir package_dir 0o700;
      Unix.mkdir cache_dir 0o700;
      write_package package_dir;
      let hash = pack_package ~root:package_dir ~output:artifact in
      with_env "BLORP_PACKAGE_CACHE" cache_dir (fun () ->
          match Blorp.Package_cache.fetch ~expected_pin:hash [ artifact ] with
          | Error errors ->
              Alcotest.failf "package fetch failed:\n%s"
                (Blorp.Package_cache.render_errors errors)
          | Ok cached ->
              Alcotest.(check string) "hash" hash cached.hash;
              Alcotest.(check bool)
                "cache path exists" true
                (Sys.file_exists
                   (Filename.concat cached.path
                      Blorp.Package_manifest.manifest_filename))))

let test_fetch_rejects_hash_mismatch () =
  with_temp_dir "blorp_package_cache_mismatch" (fun dir ->
      let package_dir = Filename.concat dir "package" in
      let cache_dir = Filename.concat dir "cache" in
      let artifact = Filename.concat dir "sample.blorpkg" in
      Unix.mkdir package_dir 0o700;
      Unix.mkdir cache_dir 0o700;
      write_package package_dir;
      let _hash = pack_package ~root:package_dir ~output:artifact in
      with_env "BLORP_PACKAGE_CACHE" cache_dir (fun () ->
          match
            Blorp.Package_cache.fetch ~expected_pin:"ffffffffffffffff"
              [ artifact ]
          with
          | Ok _ -> Alcotest.fail "mismatched package hash was accepted"
          | Error errors ->
              Alcotest.(check bool)
                "mismatch message" true
                (Blorp.Modules.contains
                   (Blorp.Package_cache.render_errors errors)
                   "hash mismatch")))

let test_hash_only_alias_resolves_from_cache () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_package_cache_alias" (fun dir ->
          let package_dir = Filename.concat dir "package" in
          let cache_dir = Filename.concat dir "cache" in
          let project_dir = Filename.concat dir "project" in
          let artifact = Filename.concat dir "sample.blorpkg" in
          Unix.mkdir package_dir 0o700;
          Unix.mkdir cache_dir 0o700;
          Unix.mkdir project_dir 0o700;
          write_package package_dir;
          let hash = pack_package ~root:package_dir ~output:artifact in
          with_env "BLORP_PACKAGE_CACHE" cache_dir (fun () ->
              match
                Blorp.Package_cache.fetch ~expected_pin:hash [ artifact ]
              with
              | Error errors ->
                  Alcotest.failf "package fetch failed:\n%s"
                    (Blorp.Package_cache.render_errors errors)
              | Ok _ -> (
                  write_file
                    (Filename.concat project_dir "blorp.toml")
                    (Printf.sprintf "[packages]\nsample = { hash = %S }\n"
                       (String.sub hash 0 16));
                  let sess = Blorp.Session.create () in
                  Blorp.Modules.init_module_paths ~sess project_dir;
                  match
                    Blorp.Modules.load_module ~sess "sample" project_dir
                  with
                  | None ->
                      Alcotest.fail
                        "hash-only cached package alias did not resolve"
                  | Some m ->
                      Alcotest.(check (option string))
                        "package origin" (Some "sample")
                        (match m.origin with
                        | Blorp.Session.Package_module id ->
                            Some (Blorp.Session.package_id_name id)
                        | Blorp.Session.Stdlib_module
                        | Blorp.Session.User_module ->
                            None)))))

let test_vendor_copies_cached_package () =
  with_temp_dir "blorp_package_vendor" (fun dir ->
      let package_dir = Filename.concat dir "package" in
      let cache_dir = Filename.concat dir "cache" in
      let vendor_dir = Filename.concat dir "vendor/sample" in
      let artifact = Filename.concat dir "sample.blorpkg" in
      Unix.mkdir package_dir 0o700;
      Unix.mkdir cache_dir 0o700;
      write_package package_dir;
      let hash = pack_package ~root:package_dir ~output:artifact in
      with_env "BLORP_PACKAGE_CACHE" cache_dir (fun () ->
          match Blorp.Package_cache.fetch ~expected_pin:hash [ artifact ] with
          | Error errors ->
              Alcotest.failf "package fetch failed:\n%s"
                (Blorp.Package_cache.render_errors errors)
          | Ok _ -> (
              match Blorp.Package_cache.vendor ~pin:hash ~dest:vendor_dir with
              | Error errors ->
                  Alcotest.failf "package vendor failed:\n%s"
                    (Blorp.Package_cache.render_errors errors)
              | Ok cached ->
                  Alcotest.(check string) "hash" hash cached.hash;
                  Alcotest.(check bool)
                    "vendor source exists" true
                    (Sys.file_exists
                       (Filename.concat vendor_dir "src/sample.brp")))))

let suite =
  [
    ( "artifact cache",
      [
        Alcotest.test_case "fetch installs verified cache entry" `Quick
          test_fetch_installs_verified_cache_entry;
        Alcotest.test_case "fetch rejects hash mismatch" `Quick
          test_fetch_rejects_hash_mismatch;
        Alcotest.test_case "hash-only alias resolves from cache" `Quick
          test_hash_only_alias_resolves_from_cache;
        Alcotest.test_case "vendor copies cached package" `Quick
          test_vendor_copies_cached_package;
      ] );
  ]
