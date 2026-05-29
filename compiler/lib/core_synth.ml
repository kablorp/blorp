(** Post-monomorphization body synthesis.

    After monomorphization produces specialized copies of generic
    [builtin] functions with concrete types, this pass re-attempts
    [Core_intrinsics.synthesize_body] to generate IR bodies.

    Only targets functions where:
    - [cf_kind = CFBuiltin] (was builtin with no pre-mono body)
    - [cf_body = None] (synthesis failed pre-mono due to generic types)
    - [cf_type_params = []] (mono has resolved all type params)

    Functions that still fail synthesis (e.g., OS builtins, functions
    with element types we don't handle) remain as builtins for
    [core_specialize] to dispatch via CKBuiltin.

    Pipeline position: after [core_mono], before [core_match]. *)

open Core

(** Strip the [__mono_*] suffix from a mangled function name.
    [sum__mono_Float_3] -> [sum]
    [sum] -> [sum] (unchanged if no mono suffix) *)
let base_name (mangled : string) : string =
  let marker = "__mono_" in
  let marker_len = String.length marker in
  let rec find i =
    if i + marker_len > String.length mangled then mangled
    else if String.sub mangled i marker_len = marker then String.sub mangled 0 i
    else find (i + 1)
  in
  find 0

let starts_with s prefix =
  let slen = String.length s in
  let plen = String.length prefix in
  slen >= plen && String.sub s 0 plen = prefix

let ends_with s suffix =
  let slen = String.length s in
  let suffix_len = String.length suffix in
  slen >= suffix_len && String.sub s (slen - suffix_len) suffix_len = suffix

let drop_prefix_if_present s prefix =
  if starts_with s prefix then
    String.sub s (String.length prefix) (String.length s - String.length prefix)
  else s

let drop_suffix_if_present s suffix =
  if ends_with s suffix then
    String.sub s 0 (String.length s - String.length suffix)
  else s

let source_name_for_synthesis (f : core_func) : string =
  let source_name = base_name f.cf_name in
  let source_name =
    match f.cf_module with
    | None -> source_name
    | Some module_path ->
        let prefix = Codegen_names.sanitize_module_name module_path ^ "__" in
        drop_prefix_if_present source_name prefix
  in
  drop_suffix_if_present source_name "__pure"

(** Attempt to synthesize a body for a monomorphized builtin.
    Returns the function unchanged if synthesis fails or is
    not applicable. *)
let try_synthesize ~(reg : Codegen_types.registry) (f : core_func) : core_func =
  if
    (not (is_builtin_kind f.cf_kind))
    || f.cf_body <> None || f.cf_type_params <> []
  then f
  else
    let func_name = source_name_for_synthesis f in
    let module_path = Option.value f.cf_module ~default:"" in
    match
      Core_intrinsics.synthesize_body_with_reg ~reg ~func_name ~module_path
        ~params:f.cf_params ~return_ty:f.cf_return_ty
    with
    | Some body ->
        (* Synthesis succeeded — promote the function from builtin to
           user-defined since it now has a concrete IR body. *)
        { f with cf_body = Some body; cf_kind = CFUser }
    | None -> f

(** Run post-mono synthesis on all declarations. *)
let synthesize_program ~(reg : Codegen_types.registry) (prog : core_program) :
    core_program =
  let rec rewrite d =
    let desc' =
      match d.cd_desc with
      | CDFunc f -> CDFunc (try_synthesize ~reg f)
      | CDPrivate inner -> CDPrivate (rewrite inner)
      | other -> other
    in
    { d with cd_desc = desc' }
  in
  List.map rewrite prog
