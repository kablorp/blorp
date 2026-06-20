type error = Package_manifest.error = {
  path : string option;
  line : int option;
  message : string;
}

let make_error = Package_manifest.make_error
let render_error = Package_manifest.render_error
let render_errors errors = String.concat "\n" (List.map render_error errors)
let magic = "blorp-package-artifact-v1\000"

let write_file path contents =
  try
    let oc = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out oc)
      (fun () -> output_string oc contents);
    Ok ()
  with Sys_error msg -> Error [ make_error ~path msg ]

let read_file path =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () ->
        let len = in_channel_length ic in
        Ok (really_input_string ic len))
  with Sys_error msg -> Error [ make_error ~path msg ]

let add_len buffer value =
  Buffer.add_string buffer (string_of_int (String.length value));
  Buffer.add_char buffer '\000';
  Buffer.add_string buffer value;
  Buffer.add_char buffer '\000'

let artifact_bytes entries =
  let buffer = Buffer.create 4096 in
  Buffer.add_string buffer magic;
  List.iter
    (fun (entry : Package_hash.entry) ->
      Buffer.add_string buffer "file\000";
      add_len buffer entry.rel_path;
      add_len buffer entry.contents)
    entries;
  Buffer.contents buffer

let write_checked_package ~root ~source_files ~output =
  match Package_hash.package_entries ~root ~source_files with
  | Error errors -> Error errors
  | Ok entries -> (
      match write_file output (artifact_bytes entries) with
      | Error _ as err -> err
      | Ok () -> Ok (Package_hash.hash_entries entries))

let starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix

let rel_path_is_safe path =
  let len = String.length path in
  len > 0
  && path.[0] <> '/'
  && (not (String.contains path '\\'))
  && (not (String.contains path '\000'))
  &&
  let parts = String.split_on_char '/' path in
  List.for_all (fun part -> part <> "" && part <> "." && part <> "..") parts
  && (path = Package_manifest.manifest_filename
     || starts_with ~prefix:"src/" path)

let read_decimal path bytes start stop =
  if stop = start then Error (make_error ~path "empty artifact length")
  else
    let rec loop i acc =
      if i = stop then Ok acc
      else
        match bytes.[i] with
        | '0' .. '9' as c ->
            let digit = Char.code c - Char.code '0' in
            if acc > (max_int - digit) / 10 then
              Error (make_error ~path "artifact length is too large")
            else loop (i + 1) ((acc * 10) + digit)
        | _ -> Error (make_error ~path "invalid artifact length")
    in
    loop start 0

let read_len_value path bytes offset =
  let len = String.length bytes in
  match String.index_from_opt bytes offset '\000' with
  | None -> Error (make_error ~path "truncated artifact length")
  | Some sep -> (
      match read_decimal path bytes offset sep with
      | Error _ as err -> err
      | Ok value_len ->
          let value_start = sep + 1 in
          if value_len < 0 || value_len > len - value_start - 1 then
            Error (make_error ~path "truncated artifact value")
          else
            let value_end = value_start + value_len in
            if bytes.[value_end] <> '\000' then
              Error (make_error ~path "artifact value missing terminator")
            else Ok (String.sub bytes value_start value_len, value_end + 1))

let parse_entries path bytes =
  let len = String.length bytes in
  let magic_len = String.length magic in
  if len < magic_len || String.sub bytes 0 magic_len <> magic then
    Error [ make_error ~path "not a blorp package artifact" ]
  else
    let seen = Hashtbl.create 16 in
    let rec loop offset acc =
      if offset = len then Ok (List.rev acc)
      else
        let marker = "file\000" in
        let marker_len = String.length marker in
        if
          offset + marker_len > len
          || String.sub bytes offset marker_len <> marker
        then Error (make_error ~path "invalid package artifact entry marker")
        else
          match read_len_value path bytes (offset + marker_len) with
          | Error _ as err -> err
          | Ok (rel_path, after_path) -> (
              if not (rel_path_is_safe rel_path) then
                Error
                  (make_error ~path
                     (Printf.sprintf "package artifact contains unsafe path %S"
                        rel_path))
              else if Hashtbl.mem seen rel_path then
                Error
                  (make_error ~path
                     (Printf.sprintf
                        "package artifact contains duplicate path %S" rel_path))
              else
                match read_len_value path bytes after_path with
                | Error _ as err -> err
                | Ok (contents, next) ->
                    Hashtbl.add seen rel_path ();
                    loop next ({ Package_hash.rel_path; contents } :: acc))
    in
    match loop magic_len [] with
    | Ok entries -> Ok entries
    | Error err -> Error [ err ]

let read path =
  match read_file path with
  | Error _ as err -> err
  | Ok bytes -> parse_entries path bytes

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

let validate_entries ~path entries =
  let seen = Hashtbl.create 16 in
  let rec loop = function
    | [] -> Ok ()
    | (entry : Package_hash.entry) :: rest ->
        if not (rel_path_is_safe entry.rel_path) then
          Error
            [
              make_error ~path
                (Printf.sprintf "package artifact contains unsafe path %S"
                   entry.rel_path);
            ]
        else if Hashtbl.mem seen entry.rel_path then
          Error
            [
              make_error ~path
                (Printf.sprintf "package artifact contains duplicate path %S"
                   entry.rel_path);
            ]
        else begin
          Hashtbl.add seen entry.rel_path ();
          loop rest
        end
  in
  loop entries

let unpack_entries ~target entries =
  match validate_entries ~path:target entries with
  | Error _ as err -> err
  | Ok () -> (
      try
        ensure_dir target;
        List.iter
          (fun (entry : Package_hash.entry) ->
            let path = Filename.concat target entry.rel_path in
            ensure_dir (Filename.dirname path);
            match write_file path entry.contents with
            | Ok () -> ()
            | Error errors -> raise (Sys_error (render_errors errors)))
          entries;
        Ok ()
      with Sys_error msg -> Error [ make_error ~path:target msg ])
