(** Architecture guardrails for trait-obligation resolution.

    Frontend phases should not grow new direct callers of Env's lower-level
    trait-bound helpers. Route trait satisfaction through structured
    obligations so deferred/generic/concrete cases stay consistent. *)

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop i =
    i + nlen <= hlen && (String.sub haystack i nlen = needle || loop (i + 1))
  in
  nlen = 0 || loop 0

let find_project_file rel =
  let rec search dir depth =
    let candidate = Filename.concat dir rel in
    if Sys.file_exists candidate then candidate
    else if depth = 0 then
      Alcotest.failf "Cannot locate %s from CWD=%s" rel (Sys.getcwd ())
    else
      let parent = Filename.dirname dir in
      if parent = dir then
        Alcotest.failf "Cannot locate %s from CWD=%s" rel (Sys.getcwd ())
      else search parent (depth - 1)
  in
  search (Sys.getcwd ()) 12

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let assert_no_direct_trait_bound_helpers rel =
  let content = read_file (find_project_file rel) in
  let forbidden = [ "type_implements_trait"; "has_trait_bound_transitive" ] in
  List.iter
    (fun needle ->
      if contains_substring content needle then
        Alcotest.failf
          "%s references %s directly; use Env.resolve_trait_obligation or \
           Env.find_unsatisfied_trait_obligation instead"
          rel needle)
    forbidden

let test_frontend_uses_trait_obligations () =
  List.iter assert_no_direct_trait_bound_helpers
    [
      "compiler/lib/infer.ml";
      "compiler/lib/typecheck.ml";
      "compiler/lib/session.ml";
    ]

let suite =
  [
    ( "trait_obligations",
      [
        Alcotest.test_case "frontend uses obligation resolver" `Quick
          test_frontend_uses_trait_obligations;
      ] );
  ]
