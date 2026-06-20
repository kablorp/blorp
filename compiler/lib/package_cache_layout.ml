type error = Package_manifest.error = {
  path : string option;
  line : int option;
  message : string;
}

let make_error = Package_manifest.make_error
let render_error = Package_manifest.render_error
let render_errors errors = String.concat "\n" (List.map render_error errors)

let default_cache_root () =
  match Sys.getenv_opt "BLORP_PACKAGE_CACHE" with
  | Some path when String.trim path <> "" -> path
  | _ ->
      let cache_base =
        match Sys.getenv_opt "XDG_CACHE_HOME" with
        | Some path when String.trim path <> "" -> path
        | _ -> (
            match Sys.getenv_opt "HOME" with
            | Some home when String.trim home <> "" ->
                Filename.concat home ".cache"
            | _ -> Filename.concat (Filename.get_temp_dir_name ()) ".cache")
      in
      Filename.concat (Filename.concat cache_base "blorp") "packages"

let algorithm_dir () = Filename.concat (default_cache_root ()) "blake3"

let short_hash hash =
  if String.length hash <= 16 then hash else String.sub hash 0 16

let cache_dir_for_hash hash =
  Filename.concat (algorithm_dir ()) (short_hash hash)

let hash_file dir = Filename.concat dir "HASH"
let ready_file dir = Filename.concat dir "READY"

let read_file path =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () ->
        let len = in_channel_length ic in
        Ok (really_input_string ic len))
  with Sys_error msg -> Error (make_error ~path msg)

let read_cached_hash dir =
  match read_file (hash_file dir) with
  | Ok hash -> Ok (String.trim hash)
  | Error err -> Error [ err ]

let normalize_pin pin =
  match Package_hash.validate_hash_pin pin with
  | Ok pin -> Ok pin
  | Error message -> Error [ make_error ("invalid package hash: " ^ message) ]

let find_cached_path pin =
  match normalize_pin pin with
  | Error _ as err -> err
  | Ok normalized -> (
      let dir = cache_dir_for_hash normalized in
      if not (Sys.file_exists (ready_file dir)) then
        Error
          [
            make_error ~path:dir
              (Printf.sprintf
                 "package hash %s is not in the local cache; run blorp package \
                  fetch"
                 normalized);
          ]
      else
        match read_cached_hash dir with
        | Error _ as err -> err
        | Ok actual_hash ->
            if Package_hash.hash_matches_pin ~pin:normalized actual_hash then
              Ok (dir, actual_hash)
            else
              Error
                [
                  make_error ~path:dir
                    (Printf.sprintf
                       "package cache entry hash %s does not match requested \
                        pin %s"
                       actual_hash normalized);
                ])
