type error = { path : string option; line : int option; message : string }

type t = {
  name : string;
  version : string option;
  license : string option;
  std_compat : string;
  exports : string list;
}

type toml_value = TomlString of string | TomlStringList of string list

let manifest_filename = "package.toml"
let current_std_compat = "preview-1"
let make_error ?path ?line message = { path; line; message }

let render_error err =
  match (err.path, err.line) with
  | Some path, Some line -> Printf.sprintf "%s:%d: %s" path line err.message
  | Some path, None -> Printf.sprintf "%s: %s" path err.message
  | None, Some line -> Printf.sprintf "line %d: %s" line err.message
  | None, None -> err.message

let trim = String.trim

let has_prefix prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix

let strip_comment line =
  let len = String.length line in
  let rec loop i in_string escaped =
    if i >= len then len
    else
      match line.[i] with
      | '#' when not in_string -> i
      | '"' when not escaped -> loop (i + 1) (not in_string) false
      | '\\' when in_string && not escaped -> loop (i + 1) in_string true
      | _ -> loop (i + 1) in_string false
  in
  let comment_start = loop 0 false false in
  String.sub line 0 comment_start

let parse_quoted_string ?path ?line value =
  let len = String.length value in
  if len < 2 || value.[0] <> '"' || value.[len - 1] <> '"' then
    Error (make_error ?path ?line "expected a quoted string")
  else
    let buffer = Buffer.create (len - 2) in
    let rec loop i =
      if i >= len - 1 then Ok (Buffer.contents buffer)
      else
        match value.[i] with
        | '\\' when i + 1 < len - 1 -> (
            match value.[i + 1] with
            | '"' ->
                Buffer.add_char buffer '"';
                loop (i + 2)
            | '\\' ->
                Buffer.add_char buffer '\\';
                loop (i + 2)
            | 'n' ->
                Buffer.add_char buffer '\n';
                loop (i + 2)
            | 't' ->
                Buffer.add_char buffer '\t';
                loop (i + 2)
            | escaped ->
                Error
                  (make_error ?path ?line
                     (Printf.sprintf "unsupported string escape \\%c" escaped)))
        | '\\' -> Error (make_error ?path ?line "unterminated string escape")
        | c ->
            Buffer.add_char buffer c;
            loop (i + 1)
    in
    loop 1

let parse_string_list ?path ?line value =
  let len = String.length value in
  if len < 2 || value.[0] <> '[' || value.[len - 1] <> ']' then
    Error (make_error ?path ?line "expected an array of quoted strings")
  else
    let inner = String.sub value 1 (len - 2) in
    let inner_len = String.length inner in
    let rec skip_spaces i =
      if i < inner_len then
        match inner.[i] with ' ' | '\t' -> skip_spaces (i + 1) | _ -> i
      else i
    in
    let rec parse_items i acc =
      let i = skip_spaces i in
      if i >= inner_len then Ok (List.rev acc)
      else if inner.[i] <> '"' then
        Error (make_error ?path ?line "expected a quoted string in array")
      else
        let rec find_end j escaped =
          if j >= inner_len then None
          else
            match inner.[j] with
            | '"' when not escaped -> Some j
            | '\\' when not escaped -> find_end (j + 1) true
            | _ -> find_end (j + 1) false
        in
        match find_end (i + 1) false with
        | None -> Error (make_error ?path ?line "unterminated string in array")
        | Some end_idx -> (
            let raw = String.sub inner i (end_idx - i + 1) in
            match parse_quoted_string ?path ?line raw with
            | Error err -> Error err
            | Ok item ->
                let after = skip_spaces (end_idx + 1) in
                if after >= inner_len then Ok (List.rev (item :: acc))
                else if inner.[after] = ',' then
                  parse_items (after + 1) (item :: acc)
                else
                  Error
                    (make_error ?path ?line "expected ',' between array items"))
    in
    parse_items 0 []

let parse_value ?path ?line ~expects_list raw =
  if expects_list then
    Result.map
      (fun items -> TomlStringList items)
      (parse_string_list ?path ?line raw)
  else
    Result.map
      (fun value -> TomlString value)
      (parse_quoted_string ?path ?line raw)

let is_supported_section = function
  | "package" | "compat" | "exports" -> true
  | _ -> false

let allowed_key section key =
  match (section, key) with
  | "package", ("name" | "version" | "license") -> Some false
  | "compat", "std" -> Some false
  | "exports", "modules" -> Some true
  | _ -> None

let field_key section key = section ^ "." ^ key

let is_identifier value =
  let len = String.length value in
  let is_first = function
    | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
    | _ -> false
  in
  let is_rest = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  len > 0
  && is_first value.[0]
  &&
  let rec loop i =
    if i >= len then true else is_rest value.[i] && loop (i + 1)
  in
  loop 1

let is_reserved_package_root = function "std" | "pkg" -> true | _ -> false

let is_module_path value =
  let parts = String.split_on_char '/' value in
  parts <> []
  && List.for_all
       (fun part -> part <> "." && part <> ".." && is_identifier part)
       parts
  && (not (has_prefix "std/" value))
  && not (has_prefix "pkg/" value)

let parse ?path source =
  let fields : (string, toml_value * int) Hashtbl.t = Hashtbl.create 8 in
  let errors = ref [] in
  let add_error ?line message =
    errors := make_error ?path ?line message :: !errors
  in
  let current_section = ref None in
  let lines = String.split_on_char '\n' source in
  List.iteri
    (fun idx raw_line ->
      let line_no = idx + 1 in
      let line = raw_line |> strip_comment |> trim in
      if line <> "" then
        if line.[0] = '[' then
          let len = String.length line in
          if len >= 3 && line.[len - 1] = ']' then begin
            let section = String.sub line 1 (len - 2) |> trim in
            current_section := Some section;
            if not (is_supported_section section) then
              add_error ~line:line_no
                (Printf.sprintf "unsupported package manifest section [%s]"
                   section)
          end
          else add_error ~line:line_no "invalid package manifest section header"
        else
          match String.index_opt line '=' with
          | None -> add_error ~line:line_no "expected key = value"
          | Some eq -> (
              match !current_section with
              | None ->
                  add_error ~line:line_no
                    "package manifest keys must be inside a section"
              | Some section -> (
                  let key = String.sub line 0 eq |> trim in
                  let raw_value =
                    String.sub line (eq + 1) (String.length line - eq - 1)
                    |> trim
                  in
                  match allowed_key section key with
                  | None ->
                      if is_supported_section section then
                        add_error ~line:line_no
                          (Printf.sprintf
                             "unsupported key %s in package manifest section \
                              [%s]"
                             key section)
                  | Some expects_list -> (
                      let storage_key = field_key section key in
                      if Hashtbl.mem fields storage_key then
                        add_error ~line:line_no
                          (Printf.sprintf
                             "duplicate key %s in package manifest section [%s]"
                             key section)
                      else
                        match
                          parse_value ?path ~line:line_no ~expects_list
                            raw_value
                        with
                        | Ok value ->
                            Hashtbl.add fields storage_key (value, line_no)
                        | Error err -> errors := err :: !errors))))
    lines;
  let find_string section key =
    match Hashtbl.find_opt fields (field_key section key) with
    | Some (TomlString value, _) -> Some value
    | _ -> None
  in
  let find_string_list section key =
    match Hashtbl.find_opt fields (field_key section key) with
    | Some (TomlStringList value, _) -> Some value
    | _ -> None
  in
  let require_string section key =
    match find_string section key with
    | Some value -> Some value
    | None ->
        add_error
          (Printf.sprintf "missing required package manifest key [%s].%s"
             section key);
        None
  in
  let require_string_list section key =
    match find_string_list section key with
    | Some value -> Some value
    | None ->
        add_error
          (Printf.sprintf "missing required package manifest key [%s].%s"
             section key);
        None
  in
  match
    ( require_string "package" "name",
      require_string "compat" "std",
      require_string_list "exports" "modules" )
  with
  | Some name, Some std_compat, Some exports ->
      let manifest =
        {
          name;
          version = find_string "package" "version";
          license = find_string "package" "license";
          std_compat;
          exports;
        }
      in
      let validation_errors = ref [] in
      let add_validation message =
        validation_errors := make_error ?path message :: !validation_errors
      in
      if not (is_identifier name) then
        add_validation
          "package name must be a Blorp identifier such as json or json_tools";
      if is_reserved_package_root name then
        add_validation
          (Printf.sprintf "package name %S is reserved by the module system"
             name);
      if exports = [] then
        add_validation "package must export at least one module";
      let seen_exports = Hashtbl.create (max 8 (List.length exports)) in
      List.iter
        (fun module_name ->
          if not (is_module_path module_name) then
            add_validation
              (Printf.sprintf "exported module %S is not a valid module path"
                 module_name)
          else if
            module_name <> name && not (has_prefix (name ^ "/") module_name)
          then
            add_validation
              (Printf.sprintf "exported module %S must be inside package %S"
                 module_name name);
          if Hashtbl.mem seen_exports module_name then
            add_validation
              (Printf.sprintf "duplicate exported module %S" module_name)
          else Hashtbl.add seen_exports module_name ())
        exports;
      if !errors <> [] || !validation_errors <> [] then
        Error (List.rev (!validation_errors @ !errors))
      else Ok manifest
  | _ -> Error (List.rev !errors)

let read path =
  if not (Sys.file_exists path) then
    Error [ make_error ~path "package manifest not found" ]
  else
    try
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> close_in ic)
        (fun () ->
          let len = in_channel_length ic in
          let source = really_input_string ic len in
          parse ~path source)
    with Sys_error msg -> Error [ make_error ~path msg ]
