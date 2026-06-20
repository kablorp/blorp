type error = Package_manifest.error = {
  path : string option;
  line : int option;
  message : string;
}

type cached_package = {
  hash : string;
  path : string;
  manifest : Package_manifest.t;
}

let make_error = Package_manifest.make_error
let render_error = Package_manifest.render_error
let render_errors errors = String.concat "\n" (List.map render_error errors)

let starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix

let is_directory path =
  try Sys.file_exists path && Sys.is_directory path with _ -> false

let read_file path =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () ->
        let len = in_channel_length ic in
        Ok (really_input_string ic len))
  with Sys_error msg -> Error (make_error ~path msg)

let write_file path contents =
  try
    let oc = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out oc)
      (fun () -> output_string oc contents);
    Ok ()
  with Sys_error msg -> Error (make_error ~path msg)

let ensure_dir path =
  let rec loop path =
    if path = "" || path = Filename.dirname path then ()
    else if Sys.file_exists path then
      if not (Sys.is_directory path) then
        raise
          (Sys_error (Printf.sprintf "%s exists and is not a directory" path))
      else ()
    else begin
      loop (Filename.dirname path);
      Unix.mkdir path 0o755
    end
  in
  loop path

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter
        (fun name -> remove_tree (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path
    end
    else Sys.remove path

let default_cache_root = Package_cache_layout.default_cache_root
let algorithm_dir = Package_cache_layout.algorithm_dir
let cache_dir_for_hash = Package_cache_layout.cache_dir_for_hash
let hash_file = Package_cache_layout.hash_file
let ready_file = Package_cache_layout.ready_file
let normalize_pin = Package_cache_layout.normalize_pin

let verify_expected_hash ?expected_pin actual =
  match expected_pin with
  | None -> Ok ()
  | Some pin -> (
      match normalize_pin pin with
      | Error _ as err -> err
      | Ok normalized ->
          if Package_hash.hash_matches_pin ~pin:normalized actual then Ok ()
          else
            Error
              [
                make_error
                  (Printf.sprintf "package hash mismatch: expected %s, found %s"
                     normalized actual);
              ])

let package_hash root source_files =
  Package_hash.hash_checked_package ~root ~source_files

let package_check root =
  match Package_check.check root with
  | Ok checked -> Ok checked
  | Error errors -> Error errors

let fresh_stage_dir () =
  let staging_root = Filename.concat (default_cache_root ()) "_staging" in
  ensure_dir staging_root;
  let rec loop attempt =
    let name =
      Printf.sprintf "pkg_%d_%06d_%d" (Unix.getpid ()) (Random.int 1_000_000)
        attempt
    in
    let path = Filename.concat staging_root name in
    if Sys.file_exists path then loop (attempt + 1)
    else begin
      Unix.mkdir path 0o755;
      path
    end
  in
  loop 0

let read_cached_hash = Package_cache_layout.read_cached_hash

let finalize_stage ~stage ~hash =
  ensure_dir (algorithm_dir ());
  let final = cache_dir_for_hash hash in
  if Sys.file_exists final then (
    match read_cached_hash final with
    | Ok existing_hash when existing_hash = hash ->
        remove_tree stage;
        Ok final
    | Ok existing_hash ->
        remove_tree stage;
        Error
          [
            make_error ~path:final
              (Printf.sprintf
                 "package cache prefix collision: existing hash %s conflicts \
                  with %s"
                 existing_hash hash);
          ]
    | Error _ ->
        remove_tree final;
        Unix.rename stage final;
        Ok final)
  else begin
    Unix.rename stage final;
    Ok final
  end

let install_entries ?expected_pin entries =
  let stage = fresh_stage_dir () in
  let bind result f =
    match result with Ok value -> f value | Error _ as err -> err
  in
  let bind_one result f =
    match result with Ok value -> f value | Error err -> Error [ err ]
  in
  let cleanup_on_error result =
    match result with
    | Ok _ as ok -> ok
    | Error _ as err ->
        (try remove_tree stage with _ -> ());
        err
  in
  let result =
    bind (Package_artifact.unpack_entries ~target:stage entries) (fun () ->
        bind (package_check stage) (fun checked ->
            bind (package_hash stage checked.Package_check.source_files)
              (fun hash ->
                bind (verify_expected_hash ?expected_pin hash) (fun () ->
                    bind_one
                      (write_file (hash_file stage) (hash ^ "\n"))
                      (fun () ->
                        bind_one
                          (write_file (ready_file stage) "ready\n")
                          (fun () ->
                            bind (finalize_stage ~stage ~hash) (fun path ->
                                Ok
                                  {
                                    hash;
                                    path;
                                    manifest = checked.Package_check.manifest;
                                  })))))))
  in
  cleanup_on_error result

let install_artifact ?expected_pin artifact_path =
  match Package_artifact.read artifact_path with
  | Error errors -> Error errors
  | Ok entries -> install_entries ?expected_pin entries

type resolved_location = {
  location_path : string;
  cleanup_location : unit -> unit;
}

let local_location_path location =
  if starts_with ~prefix:"file://" location then
    Some (String.sub location 7 (String.length location - 7))
  else if starts_with ~prefix:"http://" location then None
  else if starts_with ~prefix:"https://" location then None
  else Some location

let fresh_download_path () =
  let download_root = Filename.concat (default_cache_root ()) "_downloads" in
  ensure_dir download_root;
  let rec loop attempt =
    let path =
      Filename.concat download_root
        (Printf.sprintf "pkg_%d_%06d_%d.blorpkg" (Unix.getpid ())
           (Random.int 1_000_000) attempt)
    in
    if Sys.file_exists path then loop (attempt + 1) else path
  in
  loop 0

let read_optional path =
  match read_file path with Ok text -> String.trim text | Error _ -> ""

let wait_status_success = function
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let download_http_location location =
  let output_path = fresh_download_path () in
  let error_path = output_path ^ ".err" in
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  let err_fd =
    Unix.openfile error_path [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
  in
  let cleanup () =
    (try Sys.remove output_path with _ -> ());
    try Sys.remove error_path with _ -> ()
  in
  let close_fds () =
    (try Unix.close dev_null with _ -> ());
    try Unix.close err_fd with _ -> ()
  in
  try
    let argv =
      [|
        "curl";
        "--fail";
        "--location";
        "--silent";
        "--show-error";
        "--output";
        output_path;
        location;
      |]
    in
    let pid = Unix.create_process "curl" argv Unix.stdin dev_null err_fd in
    close_fds ();
    let _, status = Unix.waitpid [] pid in
    if wait_status_success status then
      Ok { location_path = output_path; cleanup_location = cleanup }
    else
      let detail = read_optional error_path in
      cleanup ();
      Error
        [
          make_error
            (Printf.sprintf "failed to fetch package location %S%s" location
               (if detail = "" then "" else ": " ^ detail));
        ]
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
      close_fds ();
      cleanup ();
      Error
        [
          make_error
            "package fetch needs curl for HTTP(S) locations, but curl was not \
             found";
        ]
  | Unix.Unix_error (err, fn, arg) ->
      close_fds ();
      cleanup ();
      Error
        [
          make_error
            (Printf.sprintf "failed to fetch package location %S: %s(%s): %s"
               location fn arg (Unix.error_message err));
        ]

let resolve_location location =
  match local_location_path location with
  | Some path -> Ok { location_path = path; cleanup_location = (fun () -> ()) }
  | None -> download_http_location location

let fetch ?expected_pin locations =
  let rec loop failures = function
    | [] -> Error (List.rev failures)
    | location :: rest -> (
        match resolve_location location with
        | Error errors -> loop (List.rev_append errors failures) rest
        | Ok resolved -> (
            let result =
              Fun.protect ~finally:resolved.cleanup_location (fun () ->
                  install_artifact ?expected_pin resolved.location_path)
            in
            match result with
            | Ok _ as ok -> ok
            | Error errors -> loop (List.rev_append errors failures) rest))
  in
  match locations with
  | [] -> Error [ make_error "package fetch requires at least one location" ]
  | _ -> loop [] locations

let find_cached pin =
  match Package_cache_layout.find_cached_path pin with
  | Error _ as err -> err
  | Ok (dir, actual_hash) -> (
      match package_check dir with
      | Error errors -> Error errors
      | Ok checked ->
          Ok
            {
              hash = actual_hash;
              path = dir;
              manifest = checked.Package_check.manifest;
            })

let copy_file ~src ~dst =
  match read_file src with
  | Error err -> Error [ err ]
  | Ok contents -> (
      ensure_dir (Filename.dirname dst);
      match write_file dst contents with
      | Ok () -> Ok ()
      | Error err -> Error [ err ])

let rec copy_tree ~src ~dst =
  if is_directory src then begin
    ensure_dir dst;
    Sys.readdir src |> Array.to_list |> List.sort String.compare
    |> List.fold_left
         (fun acc name ->
           match acc with
           | Error _ as err -> err
           | Ok () ->
               copy_tree ~src:(Filename.concat src name)
                 ~dst:(Filename.concat dst name))
         (Ok ())
  end
  else copy_file ~src ~dst

let vendor ~pin ~dest =
  if Sys.file_exists dest then
    Error [ make_error ~path:dest "vendor destination already exists" ]
  else
    match find_cached pin with
    | Error _ as err -> err
    | Ok cached -> (
        ensure_dir dest;
        match
          copy_file
            ~src:
              (Filename.concat cached.path Package_manifest.manifest_filename)
            ~dst:(Filename.concat dest Package_manifest.manifest_filename)
        with
        | Error _ as err -> err
        | Ok () -> (
            match
              copy_tree
                ~src:(Filename.concat cached.path "src")
                ~dst:(Filename.concat dest "src")
            with
            | Error _ as err -> err
            | Ok () -> Ok cached))
