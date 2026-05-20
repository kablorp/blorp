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
