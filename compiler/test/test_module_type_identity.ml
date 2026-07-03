(** Tests for module-local type identity inventory. *)

let parse_program source =
  match
    Blorp.Modules.parse_typecheck_source ~filename:"module_type_identity_test.brp"
      source
  with
  | Ok program -> program
  | Error err -> Alcotest.failf "expected source to parse: %s" err.message

let check_names msg expected actual =
  Alcotest.(check (list string)) msg expected actual

let test_local_type_names_include_private_wrappers_and_sort () =
  let source =
    {|
func ignored() -> Int:
    1

record Zebra {value: Int}

private union Hidden:
    HiddenCase

type alias Alias = Int

private type Native = builtin

trait IgnoredTrait:
    pure func ignored_method(value: Self) -> String
|}
  in
  let names =
    source |> parse_program
    |> Blorp.Module_type_identity.local_type_names_from_decls
  in
  check_names "local type names" [ "Alias"; "Hidden"; "Native"; "Zebra" ] names

let suite =
  [
    ( "local_type_names",
      [
        Alcotest.test_case "includes private wrappers and sorts" `Quick
          test_local_type_names_include_private_wrappers_and_sort;
      ] );
  ]
