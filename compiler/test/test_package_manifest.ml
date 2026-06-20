let expect_ok source =
  match Blorp.Package_manifest.parse source with
  | Ok manifest -> manifest
  | Error errors ->
      Alcotest.failf "expected manifest to parse, got:\n%s"
        (String.concat "\n"
           (List.map Blorp.Package_manifest.render_error errors))

let expect_error source expected =
  match Blorp.Package_manifest.parse source with
  | Ok _ -> Alcotest.fail "expected package manifest error"
  | Error errors ->
      let text =
        String.concat "\n" (List.map Blorp.Package_manifest.render_error errors)
      in
      Alcotest.(check bool)
        ("contains " ^ expected) true
        (Blorp.Modules.contains text expected)

let valid_manifest =
  {|
[package]
name = "json_tools"
version = "0.1.0"
license = "MIT"

[compat]
std = "preview-1"

[exports]
modules = ["json_tools", "json_tools/parser"]
|}

let test_parse_manifest () =
  let manifest = expect_ok valid_manifest in
  Alcotest.(check string) "name" "json_tools" manifest.name;
  Alcotest.(check (option string)) "version" (Some "0.1.0") manifest.version;
  Alcotest.(check string) "std compat" "preview-1" manifest.std_compat;
  Alcotest.(check (list string))
    "exports"
    [ "json_tools"; "json_tools/parser" ]
    manifest.exports

let test_rejects_dependency_section () =
  expect_error
    {|
[package]
name = "json_tools"

[dependencies]
other = "1.0.0"

[compat]
std = "preview-1"

[exports]
modules = ["json_tools"]
|}
    "unsupported package manifest section [dependencies]"

let test_rejects_export_outside_package () =
  expect_error
    {|
[package]
name = "json_tools"

[compat]
std = "preview-1"

[exports]
modules = ["other"]
|}
    "must be inside package"

let suite =
  [
    ( "parse",
      [
        Alcotest.test_case "valid source package manifest" `Quick
          test_parse_manifest;
        Alcotest.test_case "rejects dependency section" `Quick
          test_rejects_dependency_section;
        Alcotest.test_case "rejects export outside package" `Quick
          test_rejects_export_outside_package;
      ] );
  ]
