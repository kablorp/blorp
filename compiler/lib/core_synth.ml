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

let source_name_for_synthesis (f : core_func) : string =
  Codegen_names.source_name_for_generated_function ?module_path:f.cf_module
    f.cf_name

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
