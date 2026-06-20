type package_path = {
  package_alias : string;
  package_path : string option;
  package_hash_pin : string option;
  package_from : string list;
  package_line : int;
}

type parse_result = {
  package_paths : package_path list;
  package_errors : (int * string) list;
}

type inline_package_config =
  | InlinePackageConfig of {
      path : string option;
      hash_pin : string option;
      from : string list option;
    }
  | InlinePackageConfigInvalid
  | InlinePackageConfigUnsupportedKey of string

type pending_package_config = {
  mutable pending_line : int;
  mutable pending_path : (string * int) option;
  mutable pending_hash_pin : (string * int) option;
  mutable pending_from : (string list * int) option;
}

let has_prefix prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let strip_prefix prefix s =
  String.sub s (String.length prefix) (String.length s - String.length prefix)

let file_exists path =
  try
    let _ = Unix.stat path in
    true
  with Unix.Unix_error _ -> false

let is_directory path =
  try Sys.file_exists path && Sys.is_directory path with _ -> false

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let n = in_channel_length ic in
      really_input_string ic n)

let rec find_blorp_config_from dir =
  let config = Filename.concat dir "blorp.toml" in
  if file_exists config && not (is_directory config) then Some config
  else
    let parent = Filename.dirname dir in
    if parent = dir then None else find_blorp_config_from parent

let parse_toml_string_value value =
  let value = String.trim value in
  let len = String.length value in
  if len < 2 then None
  else
    let quote = value.[0] in
    if quote <> '"' && quote <> '\'' then None
    else
      let rec find_end i escaped =
        if i >= len then None
        else
          let c = value.[i] in
          if quote = '"' && c = '\\' && not escaped then find_end (i + 1) true
          else if c = quote && not escaped then Some i
          else find_end (i + 1) false
      in
      match find_end 1 false with
      | Some i -> Some (String.sub value 1 (i - 1))
      | None -> None

let parse_toml_string_list value =
  match Package_manifest.parse_string_list (String.trim value) with
  | Ok items -> Some items
  | Error _ -> None

let split_inline_table_fields inner =
  let len = String.length inner in
  let rec loop i start depth quote escaped acc =
    if i >= len then List.rev (String.sub inner start (len - start) :: acc)
    else
      match (quote, inner.[i]) with
      | Some q, c ->
          let next_escaped = q = '"' && c = '\\' && not escaped in
          let next_quote = if c = q && not escaped then None else quote in
          loop (i + 1) start depth next_quote next_escaped acc
      | None, (('"' | '\'') as q) -> loop (i + 1) start depth (Some q) false acc
      | None, '[' -> loop (i + 1) start (depth + 1) None false acc
      | None, ']' -> loop (i + 1) start (max 0 (depth - 1)) None false acc
      | None, ',' when depth = 0 ->
          loop (i + 1) (i + 1) depth None false
            (String.sub inner start (i - start) :: acc)
      | None, _ -> loop (i + 1) start depth None false acc
  in
  loop 0 0 0 None false []

let parse_inline_table_path value =
  let value = String.trim value in
  let len = String.length value in
  if len < 2 || value.[0] <> '{' || value.[len - 1] <> '}' then
    InlinePackageConfigInvalid
  else
    let inner = String.sub value 1 (len - 2) in
    let path = ref None in
    let hash_pin = ref None in
    let from = ref None in
    let error = ref None in
    split_inline_table_fields inner
    |> List.iter (fun raw_field ->
        if !error = None then
          match String.index_opt raw_field '=' with
          | None -> error := Some InlinePackageConfigInvalid
          | Some eq -> (
              let key = String.trim (String.sub raw_field 0 eq) in
              let raw_value =
                String.sub raw_field (eq + 1) (String.length raw_field - eq - 1)
              in
              match (key, parse_toml_string_value raw_value) with
              | "path", Some value -> path := Some value
              | "hash", Some value -> hash_pin := Some value
              | "from", _ -> (
                  match parse_toml_string_list raw_value with
                  | Some values -> from := Some values
                  | None -> error := Some InlinePackageConfigInvalid)
              | ("path" | "hash"), None ->
                  error := Some InlinePackageConfigInvalid
              | _ -> error := Some (InlinePackageConfigUnsupportedKey key)));
    match !error with
    | Some error -> error
    | None ->
        InlinePackageConfig { path = !path; hash_pin = !hash_pin; from = !from }

let parse_package_paths contents =
  let current_section = ref None in
  let package_paths = ref [] in
  let package_errors = ref [] in
  let seen_aliases = Hashtbl.create 8 in
  let pending_entries : (string, pending_package_config) Hashtbl.t =
    Hashtbl.create 8
  in
  let add_error line message =
    package_errors := (line, message) :: !package_errors
  in
  let pending_entry alias line =
    match Hashtbl.find_opt pending_entries alias with
    | Some entry ->
        entry.pending_line <- min entry.pending_line line;
        entry
    | None ->
        let entry =
          {
            pending_line = line;
            pending_path = None;
            pending_hash_pin = None;
            pending_from = None;
          }
        in
        Hashtbl.add pending_entries alias entry;
        entry
  in
  let set_path line alias path =
    let entry = pending_entry alias line in
    match entry.pending_path with
    | Some (_, first_line) ->
        add_error line
          (Printf.sprintf
             "duplicate path for package alias %S; first defined on line %d"
             alias first_line)
    | None -> entry.pending_path <- Some (path, line)
  in
  let set_hash_pin line alias hash_pin =
    let entry = pending_entry alias line in
    match entry.pending_hash_pin with
    | Some (_, first_line) ->
        add_error line
          (Printf.sprintf
             "duplicate hash for package alias %S; first defined on line %d"
             alias first_line)
    | None -> entry.pending_hash_pin <- Some (hash_pin, line)
  in
  let set_from line alias from =
    let entry = pending_entry alias line in
    match entry.pending_from with
    | Some (_, first_line) ->
        add_error line
          (Printf.sprintf
             "duplicate from for package alias %S; first defined on line %d"
             alias first_line)
    | None -> entry.pending_from <- Some (from, line)
  in
  let add_entry alias (entry : pending_package_config) =
    if not (Package_manifest.is_identifier alias) then
      add_error entry.pending_line
        (Printf.sprintf
           "package alias %S must be a Blorp identifier such as json or \
            json_legacy"
           alias)
    else if Hashtbl.mem seen_aliases alias then
      add_error entry.pending_line
        (Printf.sprintf "duplicate package alias %S" alias)
    else
      let normalized_hash_pin =
        match entry.pending_hash_pin with
        | None -> Ok None
        | Some (hash_pin, hash_line) -> (
            match Package_hash.validate_hash_pin hash_pin with
            | Ok normalized -> Ok (Some normalized)
            | Error message ->
                add_error hash_line
                  (Printf.sprintf "package alias %S hash is invalid: %s" alias
                     message);
                Error ())
      in
      match (entry.pending_path, normalized_hash_pin) with
      | None, Ok None ->
          add_error entry.pending_line
            (Printf.sprintf
               "package alias %S must define path or hash in this \
                source-package preview"
               alias)
      | _, Error () -> ()
      | path_entry, Ok package_hash_pin -> (
          let package_path =
            match path_entry with
            | None -> None
            | Some (path, line) ->
                if String.trim path = "" then begin
                  add_error line
                    (Printf.sprintf "package alias %S has an empty path" alias);
                  None
                end
                else Some path
          in
          let package_line =
            match path_entry with
            | Some (_, line) -> line
            | None -> entry.pending_line
          in
          let package_from =
            match entry.pending_from with Some (from, _) -> from | None -> []
          in
          match (path_entry, package_path) with
          | Some _, None -> ()
          | None, None | None, Some _ | Some _, Some _ ->
              Hashtbl.add seen_aliases alias ();
              package_paths :=
                {
                  package_alias = alias;
                  package_path;
                  package_hash_pin;
                  package_from;
                  package_line;
                }
                :: !package_paths)
  in
  let parse_key_value line_no line =
    match String.index_opt line '=' with
    | None -> ()
    | Some eq -> (
        let key = String.trim (String.sub line 0 eq) in
        let value =
          String.sub line (eq + 1) (String.length line - eq - 1) |> String.trim
        in
        match !current_section with
        | Some "packages" -> (
            if Filename.check_suffix key ".path" then
              let suffix_len = String.length ".path" in
              let alias = String.sub key 0 (String.length key - suffix_len) in
              match parse_toml_string_value value with
              | Some path -> set_path line_no alias path
              | None ->
                  add_error line_no
                    (Printf.sprintf
                       "package alias %S path must be a quoted string" alias)
            else if Filename.check_suffix key ".hash" then
              let suffix_len = String.length ".hash" in
              let alias = String.sub key 0 (String.length key - suffix_len) in
              match parse_toml_string_value value with
              | Some hash_pin -> set_hash_pin line_no alias hash_pin
              | None ->
                  add_error line_no
                    (Printf.sprintf
                       "package alias %S hash must be a quoted string" alias)
            else if Filename.check_suffix key ".from" then
              let suffix_len = String.length ".from" in
              let alias = String.sub key 0 (String.length key - suffix_len) in
              match parse_toml_string_list value with
              | Some from -> set_from line_no alias from
              | None ->
                  add_error line_no
                    (Printf.sprintf
                       "package alias %S from must be an array of quoted \
                        strings"
                       alias)
            else
              match parse_inline_table_path value with
              | InlinePackageConfig { path; hash_pin; from } ->
                  Option.iter (set_path line_no key) path;
                  Option.iter (set_hash_pin line_no key) hash_pin;
                  Option.iter (set_from line_no key) from;
                  if path = None && hash_pin = None then
                    add_error line_no
                      (Printf.sprintf
                         "package alias %S must use { path = \"...\" } or { \
                          hash = \"...\" } in this source-package preview"
                         key)
              | InlinePackageConfigUnsupportedKey unsupported ->
                  add_error line_no
                    (Printf.sprintf
                       "package alias %S supports only path, hash, and from in \
                        this source-package preview; unsupported key %S"
                       key unsupported)
              | InlinePackageConfigInvalid ->
                  add_error line_no
                    (Printf.sprintf
                       "package alias %S must use { path = \"...\" } or { hash \
                        = \"...\" } in this source-package preview"
                       key))
        | Some section when has_prefix "packages." section ->
            let prefix = "packages." in
            let alias = strip_prefix prefix section in
            if key = "path" then
              match parse_toml_string_value value with
              | Some path -> set_path line_no alias path
              | None ->
                  add_error line_no
                    (Printf.sprintf
                       "package alias %S path must be a quoted string" alias)
            else if key = "hash" then
              match parse_toml_string_value value with
              | Some hash_pin -> set_hash_pin line_no alias hash_pin
              | None ->
                  add_error line_no
                    (Printf.sprintf
                       "package alias %S hash must be a quoted string" alias)
            else if key = "from" then
              match parse_toml_string_list value with
              | Some from -> set_from line_no alias from
              | None ->
                  add_error line_no
                    (Printf.sprintf
                       "package alias %S from must be an array of quoted \
                        strings"
                       alias)
            else
              add_error line_no
                (Printf.sprintf
                   "package alias %S supports only path, hash, and from in \
                    this source-package preview; unsupported key %S"
                   alias key)
        | _ -> ())
  in
  List.iteri
    (fun idx raw ->
      let line_no = idx + 1 in
      let line = String.trim raw in
      if line = "" || line.[0] = '#' then ()
      else if line.[0] = '[' then
        match String.index_opt line ']' with
        | Some close when close > 1 ->
            let section = String.trim (String.sub line 1 (close - 1)) in
            current_section := Some section;
            if has_prefix "packages." section then
              let alias = strip_prefix "packages." section in
              if not (Package_manifest.is_identifier alias) then
                add_error line_no
                  (Printf.sprintf
                     "package alias %S must be a Blorp identifier such as json \
                      or json_legacy"
                     alias)
              else ignore (pending_entry alias line_no)
        | _ -> ()
      else parse_key_value line_no line)
    (String.split_on_char '\n' contents);
  Hashtbl.iter add_entry pending_entries;
  {
    package_paths = List.rev !package_paths;
    package_errors = List.rev !package_errors;
  }

let package_from_location config_dir location =
  if
    has_prefix "http://" location
    || has_prefix "https://" location
    || has_prefix "file://" location
    || not (Filename.is_relative location)
  then location
  else Filename.concat config_dir location

let package_paths_from base_dir =
  match find_blorp_config_from base_dir with
  | None -> None
  | Some config ->
      let parsed = parse_package_paths (read_file config) in
      let config_dir = Filename.dirname config in
      let package_paths =
        List.map
          (fun entry ->
            let path =
              Option.map
                (fun path ->
                  if Filename.is_relative path then
                    Filename.concat config_dir path
                  else path)
                entry.package_path
            in
            let from =
              List.map (package_from_location config_dir) entry.package_from
            in
            { entry with package_path = path; package_from = from })
          parsed.package_paths
      in
      Some (config, { parsed with package_paths })
