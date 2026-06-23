type error = Package_manifest.error = {
  path : string option;
  line : int option;
  message : string;
}

let make_error = Package_manifest.make_error
let render_error = Package_manifest.render_error
let render_errors errors = String.concat "\n" (List.map render_error errors)
let canonical_dir path = try Unix.realpath path with _ -> path

let canonical_file path =
  let path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
    else path
  in
  try Unix.realpath path with _ -> path

let normalize_path path = String.map (function '\\' -> '/' | c -> c) path

let relative_path ~root path =
  let root = canonical_dir root in
  let path = canonical_file path in
  let prefix = root ^ Filename.dir_sep in
  if
    String.length path > String.length prefix
    && String.sub path 0 (String.length prefix) = prefix
  then
    Ok
      (normalize_path
         (String.sub path (String.length prefix)
            (String.length path - String.length prefix)))
  else Error (make_error ~path "package hash file is outside package root")

let read_file path =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () ->
        let len = in_channel_length ic in
        Ok (really_input_string ic len))
  with Sys_error msg -> Error (make_error ~path msg)

let add_len buffer value =
  Buffer.add_string buffer (string_of_int (String.length value));
  Buffer.add_char buffer '\000';
  Buffer.add_string buffer value;
  Buffer.add_char buffer '\000'

let add_file buffer ~rel_path ~contents =
  Buffer.add_string buffer "file\000";
  add_len buffer rel_path;
  add_len buffer contents

type entry = { rel_path : string; contents : string }

let read_entries ~root files =
  let result =
    List.fold_left
      (fun acc path ->
        match acc with
        | Error _ as err -> err
        | Ok entries -> (
            match (relative_path ~root path, read_file path) with
            | Ok rel_path, Ok contents -> Ok ({ rel_path; contents } :: entries)
            | Error err, _ | _, Error err -> Error [ err ]))
      (Ok []) files
  in
  match result with
  | Error _ as err -> err
  | Ok entries ->
      Ok
        (List.sort
           (fun left right -> String.compare left.rel_path right.rel_path)
           entries)

let hash_entries entries =
  let buffer = Buffer.create 4096 in
  Buffer.add_string buffer "blorp-source-package-v1\000";
  List.iter
    (fun entry ->
      add_file buffer ~rel_path:entry.rel_path ~contents:entry.contents)
    entries;
  Blake3.hash_string_hex (Buffer.contents buffer)

let hash_files ~root files =
  match read_entries ~root files with
  | Error _ as err -> err
  | Ok entries -> Ok (hash_entries entries)

let package_files ~root ~source_files =
  let manifest_path = Filename.concat root Package_manifest.manifest_filename in
  manifest_path :: source_files

let package_entries ~root ~source_files =
  read_entries ~root (package_files ~root ~source_files)

let hash_checked_package ~root ~source_files =
  match package_entries ~root ~source_files with
  | Error _ as err -> err
  | Ok entries -> Ok (hash_entries entries)

let normalize_hash_pin value =
  let prefix = "blake3:" in
  let value = String.lowercase_ascii value in
  if
    String.length value >= String.length prefix
    && String.sub value 0 (String.length prefix) = prefix
  then
    String.sub value (String.length prefix)
      (String.length value - String.length prefix)
  else value

let is_hex_char = function '0' .. '9' | 'a' .. 'f' -> true | _ -> false

let validate_hash_pin value =
  let normalized = normalize_hash_pin value in
  let len = String.length normalized in
  if len < 16 || len > 64 then
    Error "package hash pins must be 16 to 64 hexadecimal characters"
  else if not (String.for_all is_hex_char normalized) then
    Error "package hash pins must contain only hexadecimal characters"
  else Ok normalized

let hash_matches_pin ~pin hash =
  let pin = normalize_hash_pin pin in
  String.length pin <= String.length hash
  && String.sub hash 0 (String.length pin) = String.lowercase_ascii pin
