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
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let test_package_paths_from_resolves_paths_and_from () =
  with_temp_dir "blorp_package_config" (fun dir ->
      let app_dir = Filename.concat dir "app" in
      let abs_artifact = Filename.concat dir "absolute.blorpkg" in
      ensure_dir app_dir;
      write_file
        (Filename.concat dir "blorp.toml")
        (Printf.sprintf
           "[packages]\n\
            sample = { path = \"vendor/sample\", hash = \
            \"BLAKE3:0123456789ABCDEF\", from = [\"artifacts/sample.blorpkg\", \
            \"file:///tmp/sample.blorpkg\", \
            \"https://example.com/sample.blorpkg\", %S] }\n"
           abs_artifact);
      match Blorp.Package_config.package_paths_from app_dir with
      | None -> Alcotest.fail "expected package config to be discovered"
      | Some (_, parsed) -> (
          Alcotest.(check int)
            "errors" 0
            (List.length parsed.Blorp.Package_config.package_errors);
          match parsed.Blorp.Package_config.package_paths with
          | [ entry ] ->
              Alcotest.(check string)
                "alias" "sample" entry.Blorp.Package_config.package_alias;
              Alcotest.(check (option string))
                "path"
                (Some (Filename.concat dir "vendor/sample"))
                entry.Blorp.Package_config.package_path;
              Alcotest.(check (option string))
                "hash" (Some "0123456789abcdef")
                entry.Blorp.Package_config.package_hash_pin;
              Alcotest.(check (list string))
                "from"
                [
                  Filename.concat dir "artifacts/sample.blorpkg";
                  "file:///tmp/sample.blorpkg";
                  "https://example.com/sample.blorpkg";
                  abs_artifact;
                ]
                entry.Blorp.Package_config.package_from
          | _ -> Alcotest.fail "expected one package alias"))

let test_package_config_rejects_unsupported_keys () =
  match
    Blorp.Package_config.parse_package_paths
      "[packages]\nsample = { path = \"vendor/sample\", url = \"https://x\" }\n"
  with
  | { Blorp.Package_config.package_errors = []; _ } ->
      Alcotest.fail "unsupported inline package key was accepted"
  | { Blorp.Package_config.package_errors; _ } ->
      Alcotest.(check bool)
        "unsupported key message" true
        (Blorp.Modules.contains
           (String.concat "\n" (List.map snd package_errors))
           "unsupported key \"url\"")

let test_package_config_rejects_sources_key () =
  match
    Blorp.Package_config.parse_package_paths
      "[packages]\n\
       sample = { hash = \"0123456789abcdef\", sources = [\"pkg.blorpkg\"] }\n"
  with
  | { Blorp.Package_config.package_errors = []; _ } ->
      Alcotest.fail "legacy sources key was accepted"
  | { Blorp.Package_config.package_errors; _ } ->
      Alcotest.(check bool)
        "unsupported sources key" true
        (Blorp.Modules.contains
           (String.concat "\n" (List.map snd package_errors))
           "unsupported key \"sources\"")

let test_package_config_rejects_reserved_alias () =
  match
    Blorp.Package_config.parse_package_paths
      "[packages]\nstd = { hash = \"0123456789abcdef\" }\n"
  with
  | { Blorp.Package_config.package_errors = []; _ } ->
      Alcotest.fail "reserved package alias was accepted"
  | { Blorp.Package_config.package_errors; package_paths } ->
      Alcotest.(check int)
        "no package paths registered" 0
        (List.length package_paths);
      Alcotest.(check bool)
        "reserved alias message" true
        (Blorp.Modules.contains
           (String.concat "\n" (List.map snd package_errors))
           "reserved")

let test_package_config_accepts_inline_comments () =
  match
    Blorp.Package_config.parse_package_paths
      "[packages] # dependency aliases\n\
       sample = { hash = \"0123456789abcdef\", from = \
       [\"https://example.com/pkg#fragment.blorpkg\"] } # remote source\n\n\
       [packages.local] # local package\n\
       path = \"vendor/local#name\" # keep # inside strings\n"
  with
  | { Blorp.Package_config.package_errors = error :: _; _ } ->
      Alcotest.failf
        "expected package config comments to parse, got line %d: %s" (fst error)
        (snd error)
  | { Blorp.Package_config.package_paths; _ } -> (
      let package_paths =
        List.sort
          (fun left right ->
            String.compare left.Blorp.Package_config.package_alias
              right.Blorp.Package_config.package_alias)
          package_paths
      in
      match package_paths with
      | [ local; sample ] ->
          Alcotest.(check string)
            "local alias" "local" local.Blorp.Package_config.package_alias;
          Alcotest.(check (option string))
            "path keeps hash" (Some "vendor/local#name")
            local.Blorp.Package_config.package_path;
          Alcotest.(check string)
            "sample alias" "sample" sample.Blorp.Package_config.package_alias;
          Alcotest.(check (list string))
            "from keeps fragment"
            [ "https://example.com/pkg#fragment.blorpkg" ]
            sample.Blorp.Package_config.package_from
      | _ -> Alcotest.fail "expected two package aliases")

let test_package_config_rejects_trailing_string_content () =
  let assert_rejects label source =
    match Blorp.Package_config.parse_package_paths source with
    | { Blorp.Package_config.package_errors = []; _ } ->
        Alcotest.failf "%s accepted trailing content" label
    | { Blorp.Package_config.package_errors; package_paths } ->
        Alcotest.(check int)
          (label ^ " registered paths")
          0
          (List.length package_paths);
        Alcotest.(check bool)
          (label ^ " mentions quoted string")
          true
          (Blorp.Modules.contains
             (String.concat "\n" (List.map snd package_errors))
             "quoted string")
  in
  assert_rejects "table form"
    "[packages.sample]\npath = \"vendor/sample\" trailing\n";
  assert_rejects "inline form"
    "[packages]\nsample = { path = \"vendor/sample\" trailing }\n"

let test_package_paths_from_uses_nearest_config () =
  with_temp_dir "blorp_package_config_nearest" (fun dir ->
      let nested = Filename.concat dir "examples/tool/src" in
      Unix.mkdir (Filename.concat dir "examples") 0o700;
      Unix.mkdir (Filename.concat dir "examples/tool") 0o700;
      ensure_dir nested;
      write_file
        (Filename.concat dir "blorp.toml")
        "[packages]\nroot_pkg = { hash = \"0123456789abcdef\" }\n";
      write_file
        (Filename.concat dir "examples/tool/blorp.toml")
        "[packages]\ntool_pkg = { hash = \"fedcba9876543210\" }\n";
      match Blorp.Package_config.package_paths_from nested with
      | None -> Alcotest.fail "expected nested blorp.toml"
      | Some (config_path, parsed) -> (
          Alcotest.(check string)
            "nearest config"
            (Filename.concat dir "examples/tool/blorp.toml")
            config_path;
          match parsed.Blorp.Package_config.package_paths with
          | [ entry ] ->
              Alcotest.(check string)
                "nearest package" "tool_pkg"
                entry.Blorp.Package_config.package_alias
          | _ -> Alcotest.fail "expected only nested package"))

let suite =
  [
    ( "config",
      [
        Alcotest.test_case "resolves package paths and from" `Quick
          test_package_paths_from_resolves_paths_and_from;
        Alcotest.test_case "rejects unsupported keys" `Quick
          test_package_config_rejects_unsupported_keys;
        Alcotest.test_case "rejects sources key" `Quick
          test_package_config_rejects_sources_key;
        Alcotest.test_case "rejects reserved alias" `Quick
          test_package_config_rejects_reserved_alias;
        Alcotest.test_case "accepts inline comments" `Quick
          test_package_config_accepts_inline_comments;
        Alcotest.test_case "rejects trailing string content" `Quick
          test_package_config_rejects_trailing_string_content;
        Alcotest.test_case "uses nearest blorp.toml" `Quick
          test_package_paths_from_uses_nearest_config;
      ] );
  ]
