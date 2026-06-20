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

let cache_hash_dirs () =
  let dir = Blorp.Package_cache_layout.algorithm_dir () in
  if Sys.file_exists dir then
    Sys.readdir dir |> Array.to_list |> List.sort String.compare
  else []

let write_matching_cache_marker hash ~ready =
  let algorithm_dir = Blorp.Package_cache_layout.algorithm_dir () in
  ensure_dir algorithm_dir;
  let final_dir = Blorp.Package_cache_layout.cache_dir_for_hash hash in
  ensure_dir final_dir;
  write_file (Blorp.Package_cache_layout.hash_file final_dir) (hash ^ "\n");
  if ready then
    write_file (Blorp.Package_cache_layout.ready_file final_dir) "ready\n";
  final_dir

let write_package_contents root answer =
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
    (Printf.sprintf "pure func answer() -> Int:\n    %d\n" answer)

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

let test_fetch_accepts_matching_prefix_pin () =
  with_temp_dir "blorp_package_cache_prefix" (fun dir ->
      let package_dir = Filename.concat dir "package" in
      let cache_dir = Filename.concat dir "cache" in
      let artifact = Filename.concat dir "sample.blorpkg" in
      Unix.mkdir package_dir 0o700;
      Unix.mkdir cache_dir 0o700;
      write_package package_dir;
      let hash = pack_package ~root:package_dir ~output:artifact in
      let prefix = String.sub hash 0 16 in
      with_env "BLORP_PACKAGE_CACHE" cache_dir (fun () ->
          match Blorp.Package_cache.fetch ~expected_pin:prefix [ artifact ] with
          | Error errors ->
              Alcotest.failf "package fetch failed:\n%s"
                (Blorp.Package_cache.render_errors errors)
          | Ok cached ->
              Alcotest.(check string) "full hash" hash cached.hash;
              Alcotest.(check string)
                "cache directory uses canonical prefix" prefix
                (Filename.basename cached.path)))

let test_fetch_replaces_matching_incomplete_cache_entry () =
  with_temp_dir "blorp_package_cache_incomplete" (fun dir ->
      let package_dir = Filename.concat dir "package" in
      let cache_dir = Filename.concat dir "cache" in
      let artifact = Filename.concat dir "sample.blorpkg" in
      Unix.mkdir package_dir 0o700;
      Unix.mkdir cache_dir 0o700;
      write_package package_dir;
      let hash = pack_package ~root:package_dir ~output:artifact in
      with_env "BLORP_PACKAGE_CACHE" cache_dir (fun () ->
          let final_dir = write_matching_cache_marker hash ~ready:false in
          match Blorp.Package_cache.fetch ~expected_pin:hash [ artifact ] with
          | Error errors ->
              Alcotest.failf "package fetch failed:\n%s"
                (Blorp.Package_cache.render_errors errors)
          | Ok cached ->
              Alcotest.(check string) "hash" hash cached.hash;
              Alcotest.(check string) "cache path" final_dir cached.path;
              Alcotest.(check bool)
                "ready marker restored" true
                (Sys.file_exists
                   (Blorp.Package_cache_layout.ready_file final_dir));
              Alcotest.(check bool)
                "package usable after replacement" true
                (Result.is_ok (Blorp.Package_cache.find_cached hash))))

let test_fetch_replaces_matching_invalid_cache_entry () =
  with_temp_dir "blorp_package_cache_invalid" (fun dir ->
      let package_dir = Filename.concat dir "package" in
      let cache_dir = Filename.concat dir "cache" in
      let artifact = Filename.concat dir "sample.blorpkg" in
      Unix.mkdir package_dir 0o700;
      Unix.mkdir cache_dir 0o700;
      write_package package_dir;
      let hash = pack_package ~root:package_dir ~output:artifact in
      with_env "BLORP_PACKAGE_CACHE" cache_dir (fun () ->
          let final_dir = write_matching_cache_marker hash ~ready:true in
          match Blorp.Package_cache.fetch ~expected_pin:hash [ artifact ] with
          | Error errors ->
              Alcotest.failf "package fetch failed:\n%s"
                (Blorp.Package_cache.render_errors errors)
          | Ok cached ->
              Alcotest.(check string) "hash" hash cached.hash;
              Alcotest.(check string) "cache path" final_dir cached.path;
              Alcotest.(check bool)
                "package usable after replacement" true
                (Result.is_ok (Blorp.Package_cache.find_cached hash))))

let test_fetch_replaces_forged_matching_hash_cache_entry () =
  with_temp_dir "blorp_package_cache_forged" (fun dir ->
      let package_dir = Filename.concat dir "package" in
      let cache_dir = Filename.concat dir "cache" in
      let artifact = Filename.concat dir "sample.blorpkg" in
      Unix.mkdir package_dir 0o700;
      Unix.mkdir cache_dir 0o700;
      write_package package_dir;
      let hash = pack_package ~root:package_dir ~output:artifact in
      with_env "BLORP_PACKAGE_CACHE" cache_dir (fun () ->
          let final_dir = write_matching_cache_marker hash ~ready:true in
          write_package_contents final_dir 99;
          match Blorp.Package_cache.fetch ~expected_pin:hash [ artifact ] with
          | Error errors ->
              Alcotest.failf "package fetch failed:\n%s"
                (Blorp.Package_cache.render_errors errors)
          | Ok cached ->
              Alcotest.(check string) "hash" hash cached.hash;
              Alcotest.(check string) "cache path" final_dir cached.path;
              Alcotest.(check string)
                "verified package source restored"
                "pure func answer() -> Int:\n    42\n"
                (let path = Filename.concat final_dir "src/sample.brp" in
                 let ic = open_in path in
                 Fun.protect
                   ~finally:(fun () -> close_in ic)
                   (fun () -> really_input_string ic (in_channel_length ic)))))

let test_find_cached_rejects_tampered_cache_contents () =
  with_temp_dir "blorp_package_cache_tampered_find" (fun dir ->
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
          | Ok cached -> (
              write_package_contents cached.path 99;
              match Blorp.Package_cache.find_cached hash with
              | Ok _ -> Alcotest.fail "tampered cached package was accepted"
              | Error errors ->
                  Alcotest.(check bool)
                    "tamper message" true
                    (Blorp.Modules.contains
                       (Blorp.Package_cache.render_errors errors)
                       "content hash mismatch"))))

let test_fetch_rejects_hash_mismatch () =
  with_temp_dir "blorp_package_cache_mismatch" (fun dir ->
      let package_dir = Filename.concat dir "package" in
      let cache_dir = Filename.concat dir "cache" in
      let artifact = Filename.concat dir "sample.blorpkg" in
      Unix.mkdir package_dir 0o700;
      Unix.mkdir cache_dir 0o700;
      write_package package_dir;
      let hash = pack_package ~root:package_dir ~output:artifact in
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
                   "hash mismatch");
              Alcotest.(check bool)
                "actual package not cached" true
                (Result.is_error (Blorp.Package_cache.find_cached hash));
              Alcotest.(check (list string))
                "no cache hash directories" [] (cache_hash_dirs ())))

let test_fetch_rejects_corrupt_artifact_without_cache_entry () =
  with_temp_dir "blorp_package_cache_corrupt" (fun dir ->
      let cache_dir = Filename.concat dir "cache" in
      let artifact = Filename.concat dir "corrupt.blorpkg" in
      Unix.mkdir cache_dir 0o700;
      write_file artifact "not a blorp package artifact";
      with_env "BLORP_PACKAGE_CACHE" cache_dir (fun () ->
          match
            Blorp.Package_cache.fetch ~expected_pin:"ffffffffffffffff"
              [ artifact ]
          with
          | Ok _ -> Alcotest.fail "corrupt package artifact was accepted"
          | Error _ ->
              Alcotest.(check (list string))
                "no cache hash directories" [] (cache_hash_dirs ())))

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
                        | Blorp.Session.Native_package_module _
                        | Blorp.Session.Stdlib_module
                        | Blorp.Session.User_module ->
                            None)))))

let test_vendor_rejects_tampered_cache_without_writing_destination () =
  with_temp_dir "blorp_package_vendor_tampered" (fun dir ->
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
          | Ok cached -> (
              write_package_contents cached.path 99;
              match Blorp.Package_cache.vendor ~pin:hash ~dest:vendor_dir with
              | Ok _ -> Alcotest.fail "tampered cached package was vendored"
              | Error errors ->
                  Alcotest.(check bool)
                    "tamper message" true
                    (Blorp.Modules.contains
                       (Blorp.Package_cache.render_errors errors)
                       "content hash mismatch");
                  Alcotest.(check bool)
                    "vendor destination absent" false
                    (Sys.file_exists vendor_dir))))

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
        Alcotest.test_case "fetch accepts matching prefix pin" `Quick
          test_fetch_accepts_matching_prefix_pin;
        Alcotest.test_case "fetch replaces matching incomplete cache entry"
          `Quick test_fetch_replaces_matching_incomplete_cache_entry;
        Alcotest.test_case "fetch replaces matching invalid cache entry" `Quick
          test_fetch_replaces_matching_invalid_cache_entry;
        Alcotest.test_case "fetch replaces forged matching hash cache entry"
          `Quick test_fetch_replaces_forged_matching_hash_cache_entry;
        Alcotest.test_case "find_cached rejects tampered cache contents" `Quick
          test_find_cached_rejects_tampered_cache_contents;
        Alcotest.test_case "fetch rejects hash mismatch" `Quick
          test_fetch_rejects_hash_mismatch;
        Alcotest.test_case "fetch rejects corrupt artifact without cache entry"
          `Quick test_fetch_rejects_corrupt_artifact_without_cache_entry;
        Alcotest.test_case "hash-only alias resolves from cache" `Quick
          test_hash_only_alias_resolves_from_cache;
        Alcotest.test_case
          "vendor rejects tampered cache without writing destination" `Quick
          test_vendor_rejects_tampered_cache_without_writing_destination;
        Alcotest.test_case "vendor copies cached package" `Quick
          test_vendor_copies_cached_package;
      ] );
  ]
