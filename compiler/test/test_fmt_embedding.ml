let contains_substring source needle =
  let source_len = String.length source in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else if needle_len > source_len then false
  else
    let rec loop index =
      if index > source_len - needle_len then false
      else if String.sub source index needle_len = needle then true
      else loop (index + 1)
    in
    loop 0

let test_embedded_formatter_source_includes_main () =
  if Blorp.Embedded_formatter.files = [] then
    Alcotest.fail "embedded formatter source missing; run make unit-test"
  else begin
    Alcotest.(check bool)
      "main formatter source embedded" true
      (List.exists
         (fun (path, _) -> path = Blorp.Embedded_formatter.main_path)
         Blorp.Embedded_formatter.files);
    match Blorp.Embedded_formatter.find Blorp.Embedded_formatter.main_path with
    | Some source ->
        Alcotest.(check bool)
          "main source defines entry point" true
          (contains_substring source "func main")
    | None -> Alcotest.fail "embedded formatter main source not found"
  end

let cleanup_dir path =
  let rec cleanup path =
    try
      match (Unix.lstat path).Unix.st_kind with
      | Unix.S_DIR ->
          Sys.readdir path
          |> Array.iter (fun name -> cleanup (Filename.concat path name));
          Unix.rmdir path
      | _ -> Sys.remove path
    with _ -> ()
  in
  cleanup path

let with_env name value f =
  let old_value = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () ->
      match old_value with
      | Some old -> Unix.putenv name old
      | None -> Unix.putenv name "")
    (fun () ->
      Unix.putenv name value;
      f ())

let test_format_string_works_outside_repo_cwd () =
  let original_cwd = Sys.getcwd () in
  let temp_dir = Filename.temp_file "blorp-fmt-embedding-" ".tmp" in
  Sys.remove temp_dir;
  Unix.mkdir temp_dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir original_cwd;
      cleanup_dir temp_dir)
    (fun () ->
      Sys.chdir temp_dir;
      let source = "func main(args: List[String]):\n\tprint(\"hi\")\n" in
      match Blorp.Fmt.format_string source with
      | Ok formatted ->
          Alcotest.(check bool)
            "formatted source contains main" true
            (contains_substring formatted "func main")
      | Error msg -> Alcotest.fail msg)

let test_filesystem_std_prefers_filesystem_formatter () =
  with_env "BLORP_STD" "std" (fun () ->
      match Blorp.Fmt.formatter_source_kind_for_tests () with
      | Ok kind -> Alcotest.(check string) "source kind" "filesystem" kind
      | Error msg -> Alcotest.fail msg)

let test_ownerless_old_formatter_lock_is_stale () =
  let lock_dir = Filename.temp_file "blorp-fmt-lock-" ".lock" in
  Sys.remove lock_dir;
  Unix.mkdir lock_dir 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup_dir lock_dir)
    (fun () ->
      let old_time = Unix.gettimeofday () -. 10.0 in
      Unix.utimes lock_dir old_time old_time;
      Alcotest.(check bool)
        "ownerless old lock is stale" true
        (Blorp.Fmt.formatter_lock_is_stale_for_tests lock_dir))

let test_live_owned_formatter_lock_is_not_stale () =
  let lock_dir = Filename.temp_file "blorp-fmt-lock-" ".lock" in
  Sys.remove lock_dir;
  Unix.mkdir lock_dir 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup_dir lock_dir)
    (fun () ->
      let owner_path = Filename.concat lock_dir "owner.pid" in
      let oc = open_out owner_path in
      Fun.protect
        ~finally:(fun () -> close_out oc)
        (fun () -> Printf.fprintf oc "%d\n" (Unix.getpid ()));
      Alcotest.(check bool)
        "live owner lock is not stale" false
        (Blorp.Fmt.formatter_lock_is_stale_for_tests lock_dir))

let suite =
  [
    ( "embedding",
      [
        Alcotest.test_case "embedded source includes main" `Quick
          test_embedded_formatter_source_includes_main;
        Alcotest.test_case "formatting works outside repo cwd" `Slow
          test_format_string_works_outside_repo_cwd;
        Alcotest.test_case "filesystem std prefers filesystem formatter" `Quick
          test_filesystem_std_prefers_filesystem_formatter;
        Alcotest.test_case "ownerless old lock is stale" `Quick
          test_ownerless_old_formatter_lock_is_stale;
        Alcotest.test_case "live owned lock is not stale" `Quick
          test_live_owned_formatter_lock_is_not_stale;
      ] );
  ]
