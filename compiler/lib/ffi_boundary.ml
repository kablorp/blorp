(** Shared FFI argument-boundary classification.

    Typecheck and C emission must agree on whether a foreign argument is passed
    by value, defensively copied, explicitly borrowed, or rejected. Keeping that
    in one module prevents the safety rule from drifting between phases. *)

open Ast

type arg_mode = DefaultCopyMode | ExplicitBorrowMode
type copy_kind = StringCopy | BytesCopy

type copy_spec = {
  copy_kind : copy_kind;
  c_type : string;
  copy_fn : string;
  temp_prefix : string;
}

type rejected_default_reason =
  | ManagedValue
  | UnknownLayout of string
  | InvalidValueType of string

type arg_policy =
  | ScalarByValue
  | DefensiveCopy of copy_spec
  | ExplicitBorrow
  | RejectedDefault of rejected_default_reason

type metadata_field = ForeignCName | ForeignInclude | ForeignLinkFlag

type metadata_validation_error = {
  field : metadata_field;
  value : string;
  reason : string;
}

let string_copy_spec =
  {
    copy_kind = StringCopy;
    c_type = "blorp_String*";
    copy_fn = "blorp_string_copy_ffi";
    temp_prefix = "__ffi_string_copy_";
  }

let bytes_copy_spec =
  {
    copy_kind = BytesCopy;
    c_type = "blorp_Bytes*";
    copy_fn = "blorp_bytes_copy_ffi";
    temp_prefix = "__ffi_bytes_copy_";
  }

let rec resolve_copy_alias (metadata : Core_type_layout.metadata) seen ty =
  match Core_type_layout.normalize_for_ownership ty with
  | TyNamed (name, args) -> (
      match metadata.lookup_alias name with
      | Some (params, target)
        when (not (List.mem name seen)) && List.length params = List.length args
        ->
          let target = Core_type_layout.apply_alias_subst params args target in
          resolve_copy_alias metadata (name :: seen) target
      | Some _ | None -> TyNamed (name, args))
  | ty -> ty

let copy_spec_for_type metadata ty =
  match resolve_copy_alias metadata [] ty with
  | TyNamed ("String", []) -> Some string_copy_spec
  | TyNamed ("Bytes", []) -> Some bytes_copy_spec
  | _ -> None

let classify_arg ~(metadata : Core_type_layout.metadata) ~mode ty =
  match mode with
  | ExplicitBorrowMode -> ExplicitBorrow
  | DefaultCopyMode -> (
      match copy_spec_for_type metadata ty with
      | Some spec -> DefensiveCopy spec
      | None -> (
          match Core_type_layout.classify metadata ty with
          | Core_type_layout.Known { ownership = Core_type_layout.Unmanaged; _ }
            ->
              ScalarByValue
          | Core_type_layout.Known { ownership = Core_type_layout.Managed; _ }
            ->
              RejectedDefault ManagedValue
          | Core_type_layout.Unknown_named name ->
              RejectedDefault (UnknownLayout name)
          | Core_type_layout.Invalid_value_type msg ->
              RejectedDefault (InvalidValueType msg)))

let rejected_default_reason_to_string = function
  | ManagedValue -> "managed value"
  | UnknownLayout name -> Printf.sprintf "unknown type layout for %s" name
  | InvalidValueType msg -> msg

let metadata_field_to_string = function
  | ForeignCName -> "C function name"
  | ForeignInclude -> "include path"
  | ForeignLinkFlag -> "link flag"

let metadata_validation_error_to_string err =
  Printf.sprintf "Invalid foreign %s %S: %s"
    (metadata_field_to_string err.field)
    err.value err.reason

let error field value reason = Error { field; value; reason }
let is_ascii_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
let is_ascii_digit c = c >= '0' && c <= '9'
let is_c_ident_start c = is_ascii_alpha c || c = '_'
let is_c_ident_continue c = is_c_ident_start c || is_ascii_digit c

let has_prefix prefix s =
  let prefix_len = String.length prefix in
  String.length s >= prefix_len && String.sub s 0 prefix_len = prefix

let exists_char pred s =
  let rec loop i =
    if i >= String.length s then false else pred s.[i] || loop (i + 1)
  in
  loop 0

let has_control_char s =
  exists_char (fun c -> Char.code c < 32 || Char.code c = 127) s

let validate_c_name name =
  if name = "" then error ForeignCName name "must not be empty"
  else if not (is_c_ident_start name.[0]) then
    error ForeignCName name "must start with an ASCII letter or underscore"
  else if exists_char (fun c -> not (is_c_ident_continue c)) name then
    error ForeignCName name
      "must contain only ASCII letters, digits, and underscores"
  else Ok name

let is_include_char c =
  is_ascii_alpha c || is_ascii_digit c || c = '_' || c = '-' || c = '.'
  || c = '/'

let validate_include_path include_path =
  if include_path = "" then
    error ForeignInclude include_path "must not be empty"
  else if include_path.[0] = '/' then
    error ForeignInclude include_path "must be source-relative, not absolute"
  else if has_control_char include_path then
    error ForeignInclude include_path "must not contain control characters"
  else if exists_char (fun c -> not (is_include_char c)) include_path then
    error ForeignInclude include_path
      "must contain only ASCII letters, digits, '/', '.', '_', and '-'"
  else
    let parts = String.split_on_char '/' include_path in
    if List.exists (fun part -> part = "" || part = "." || part = "..") parts
    then
      error ForeignInclude include_path
        "must not contain empty, '.', or '..' path segments"
    else Ok include_path

let is_link_path_char c =
  is_ascii_alpha c || is_ascii_digit c || c = '_' || c = '-' || c = '.'
  || c = '/' || c = '@' || c = '+'

let is_link_name_char c =
  is_ascii_alpha c || is_ascii_digit c || c = '_' || c = '-' || c = '.'
  || c = '+'

let validate_link_path_token flag token =
  if String.length token <= 2 then
    error ForeignLinkFlag flag "search path flags must include a path"
  else
    let path = String.sub token 2 (String.length token - 2) in
    if exists_char (fun c -> not (is_link_path_char c)) path then
      error ForeignLinkFlag flag
        "search paths may contain only ASCII letters, digits, '/', '.', '_', \
         '-', '@', and '+'"
    else Ok token

let validate_library_token flag token =
  if String.length token <= 2 then
    error ForeignLinkFlag flag "library flags must include a library name"
  else
    let name = String.sub token 2 (String.length token - 2) in
    if exists_char (fun c -> not (is_link_name_char c)) name then
      error ForeignLinkFlag flag
        "library names may contain only ASCII letters, digits, '.', '_', '-', \
         and '+'"
    else Ok token

let validate_framework_name flag name =
  if name = "" then
    error ForeignLinkFlag flag "-framework must be followed by a framework name"
  else if exists_char (fun c -> not (is_link_name_char c)) name then
    error ForeignLinkFlag flag
      "framework names may contain only ASCII letters, digits, '.', '_', '-', \
       and '+'"
  else Ok name

let split_link_flag flag = String.split_on_char ' ' (String.trim flag)

let validate_link_tokens flag tokens =
  let rec loop = function
    | [] -> Ok flag
    | "-framework" :: name :: rest -> (
        match validate_framework_name flag name with
        | Ok _ -> loop rest
        | Error _ as err -> err)
    | [ "-framework" ] ->
        error ForeignLinkFlag flag
          "-framework must be followed by a framework name"
    | "-pthread" :: rest -> loop rest
    | token :: rest when has_prefix "-l" token -> (
        match validate_library_token flag token with
        | Ok _ -> loop rest
        | Error _ as err -> err)
    | token :: rest when has_prefix "-L" token || has_prefix "-I" token -> (
        match validate_link_path_token flag token with
        | Ok _ -> loop rest
        | Error _ as err -> err)
    | token :: _ ->
        error ForeignLinkFlag flag
          (Printf.sprintf
             "unsupported token %S; allowed forms are -lNAME, -LDIR, -IDIR, \
              -framework NAME, and -pthread"
             token)
  in
  loop tokens

let validate_link_flag flag =
  if flag = "" then error ForeignLinkFlag flag "must not be empty"
  else if has_control_char flag then
    error ForeignLinkFlag flag "must not contain control characters"
  else
    let tokens = split_link_flag flag in
    if List.exists (( = ) "") tokens then
      error ForeignLinkFlag flag "must not contain empty shell-style tokens"
    else validate_link_tokens flag tokens

let link_flag_cc_args flag =
  match validate_link_flag flag with
  | Ok _ -> split_link_flag flag
  | Error err -> invalid_arg (metadata_validation_error_to_string err)

let link_flags_cc_args flags = List.concat_map link_flag_cc_args flags

let collect_validation_error result errors =
  match result with Ok _ -> errors | Error err -> err :: errors

let validate_metadata (foreign : Ast.foreign_func) =
  let errors =
    collect_validation_error (validate_c_name foreign.foreign_name) []
  in
  let errors =
    List.fold_left
      (fun errors include_path ->
        collect_validation_error (validate_include_path include_path) errors)
      errors foreign.foreign_includes
  in
  let errors =
    List.fold_left
      (fun errors (_platform, flag) ->
        collect_validation_error (validate_link_flag flag) errors)
      errors foreign.foreign_link_flags
  in
  List.rev errors

let metadata_for_env (env : Env.env) =
  let is_value_record_name name = Env.is_value_record env name in
  let is_enum_name name =
    match Env.get_type_kind env name with Some TypeEnum -> true | _ -> false
  in
  let is_managed_name name =
    match Env.get_record env name with
    | Some _ -> not (is_value_record_name name)
    | None -> (
        match Env.get_type_kind env name with
        | Some TypeUnion -> true
        | Some TypeEnum | Some TypeBuiltin | Some TypeResource | None -> false)
  in
  Core_type_layout.metadata ~is_managed_name ~is_value_record_name ~is_enum_name
    ~lookup_alias:(Env.get_alias env) ()
