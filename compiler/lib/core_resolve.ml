(** Post-lowering resolution pass: tag [CCall] instances with a
    concrete [call_kind] based on a name-lookup env built from the
    [core_program] itself.

    {1 Motivation}

    [Core_lower] emits every [CCall] with [CKUnknown] because it has no
    notion of the surrounding program. A downstream emitter that needs
    to distinguish user / foreign / builtin / closure calls would
    otherwise have to re-implement name lookups at every call site —
    exactly the coupling that blew up the legacy [Codegen_expr].

    This pass walks the program once, collects the set of user-defined,
    foreign, and constructor names, then rewrites every [CKUnknown] call
    to the most precise call kind it can prove:

    - Foreign functions become [CKForeign { fc_c_name; fc_arg_passing }].
    - User functions, constructors, impl methods, and imported source
      functions become [CKUser (name, def_id)] when a def-id is known.
    - Runtime-backed builtins become [CKBuiltin c_name] through the
      centralized [Codegen_builtins] registry.
    - First-class function calls become [CKClosure].
    - Type-dispatched stdlib operations that a later pass specializes
      stay [CKUnknown].

    Import aliases, module-qualified calls, and UFCS all share the same
    module-function resolver so builtin lookups and prefixed source
    function lookups stay in one place. *)

open Core

type env = {
  user_funcs : (string, int) Hashtbl.t;
  user_value_types : (string, Ast.type_expr) Hashtbl.t;
  foreign_funcs : (string, foreign_call) Hashtbl.t;
  builtin_funcs : (string, string) Hashtbl.t;
  constructor_names : (string, unit) Hashtbl.t;
  import_aliases : (string, string * string) Hashtbl.t;
  module_imports : (string, (string, string * string) Hashtbl.t) Hashtbl.t;
}
(** The environment the resolver builds by walking a program once.

    - [user_funcs]: user-defined function names → [def_id] of the
      target (A4.2). Keyed by the post-flatten [cf_name] (i.e. what
      call sites will look up). The [def_id] populates
      [CKUser (name, Some def_id)] so [Core_emit] can mangle the C
      symbol via [Codegen_names.mangle_by_def_id] without reaching
      back through [env].
    - [builtin_funcs]: bodyless std builtin function names → runtime C
      builtin name. This includes monomorphized builtin declarations such as
      [std_vector__map__mono_3_Int_Int], which must remain [CKBuiltin] so
      [Core_specialize] can apply type/layout-specific rewrites instead of
      being mistaken for first-class closures.
    - [foreign_funcs]: foreign function names → their user-specified
      [c_name] and argument-passing mode (bypass — no mangling).
    - [constructor_names]: set of in-scope constructor names. Used for
      the [is_union_constructor] classification in [Core_emit]. *)

let starts_with s prefix =
  let slen = String.length s in
  let plen = String.length prefix in
  slen >= plen && String.sub s 0 plen = prefix

let ends_with s suffix =
  let slen = String.length s in
  let suffix_len = String.length suffix in
  slen >= suffix_len && String.sub s (slen - suffix_len) suffix_len = suffix

let strip_mono_suffix name =
  let marker = "__mono_" in
  let marker_len = String.length marker in
  let rec find i =
    if i + marker_len > String.length name then name
    else if String.sub name i marker_len = marker then String.sub name 0 i
    else find (i + 1)
  in
  find 0

let source_name_for_builtin_lookup (f : core_func) : string =
  let source_name = strip_mono_suffix f.cf_name in
  let source_name =
    match f.cf_module with
    | None -> source_name
    | Some module_path ->
        let prefix = Codegen_names.sanitize_module_name module_path ^ "__" in
        if starts_with source_name prefix then
          String.sub source_name (String.length prefix)
            (String.length source_name - String.length prefix)
        else source_name
  in
  let pure_suffix = "__pure" in
  if ends_with source_name pure_suffix then
    String.sub source_name 0
      (String.length source_name - String.length pure_suffix)
  else source_name

(** Build a resolution env from a core program. *)
let collect_env ~import_aliases ~module_imports (prog : core_program) : env =
  let env =
    {
      user_funcs = Hashtbl.create 64;
      user_value_types = Hashtbl.create 32;
      foreign_funcs = Hashtbl.create 16;
      builtin_funcs = Hashtbl.create 32;
      constructor_names = Hashtbl.create 32;
      import_aliases;
      module_imports;
    }
  in
  let remember_bodyless_builtin (f : core_func) =
    match f.cf_module with
    | None -> ()
    | Some module_path -> (
        let source_name = source_name_for_builtin_lookup f in
        (* Only generated/prefixed names are globally addressable here.
           Bare bodyless declarations such as [get] can exist in
           multiple std modules (list/vector) and must resolve through the
           call site's import table or first-argument type instead. *)
        if f.cf_name <> source_name then
          match Codegen_builtins.lookup module_path source_name with
          | Some c_name -> Hashtbl.replace env.builtin_funcs f.cf_name c_name
          | None -> ())
  in
  let rec visit_decl (d : core_decl) =
    match d.cd_desc with
    | CDFunc f when f.cf_body <> None -> (
        match f.cf_kind with
        | CFForeign { c_name; arg_passing; _ } ->
            Hashtbl.replace env.foreign_funcs f.cf_name
              { fc_c_name = c_name; fc_arg_passing = arg_passing }
        | _ -> Hashtbl.replace env.user_funcs f.cf_name f.cf_def_id)
    | CDFunc f -> (
        match f.cf_kind with
        | CFForeign { c_name; arg_passing; _ } ->
            Hashtbl.replace env.foreign_funcs f.cf_name
              { fc_c_name = c_name; fc_arg_passing = arg_passing }
        | CFBuiltin -> remember_bodyless_builtin f
        | _ -> ())
    | CDImpl i ->
        (* Register impl methods with their mangled names (Trait_method_Type)
           so trait method calls resolve to CKUser. Skip generic impls — they
           get monomorphized later and emit_impl also skips them. Mangling
           must use the same concrete impl-key helper as
           [Core_trait_resolve.collect_registry] and [Core_emit.emit_impl] so
           the name the call-site rewrite produces matches the definition
           the emitter generates (otherwise tuple / future generic-impl
           cases silently produce link-time name mismatches).

           A4.3 will swap the [Printf.sprintf] mangling for
           [mangle_by_def_id]; for now the name-based scheme is kept but
           the value stored is the method's [cf_def_id] (not the mangled
           string), so the same hashtable works for both schemes. *)
        if not (Codegen_types.has_type_vars i.ci_for_type) then begin
          let type_name =
            match Codegen_types.type_key_for_impl i.ci_for_type with
            | Some n -> n
            | None -> "Unknown"
          in
          List.iter
            (fun (m : core_func) ->
              let mangled =
                Printf.sprintf "%s_%s_%s" i.ci_trait m.cf_name type_name
              in
              Hashtbl.replace env.user_funcs mangled m.cf_def_id)
            i.ci_methods
        end
    | CDType t ->
        (* A4.5: field-ful constructors are emitted as real C
           functions ([Option* Some(...)]), so their call sites
           mangle to [__def_N_Some] via [CKUser] + [user_call_c_name].
           Nullary constructors are emitted as C [#define]s expanding
           to a static instance pointer — they stay bare because a
           mangled macro name can't be expanded at non-macro call
           sites. Variants without a [variant_def_id] (runtime
           bypass — Option/Result/ConcurrencyError from [env_builtins])
           don't get registered in user_funcs, so their call sites
           fall back to bare names matching runtime conventions. *)
        List.iter
          (fun (v : Ast.variant) ->
            (match v.variant_def_id with
            | Some id when v.variant_fields <> [] ->
                Hashtbl.replace env.user_funcs v.variant_name id
            | _ -> ());
            Hashtbl.replace env.constructor_names v.variant_name ())
          t.type_variants
    | CDVar v ->
        (* Global vars (module constants like [PI], [E]) need to be in the
           symbol table so [rewrite_imported_var] can redirect bare-name
           references (`PI`) to the prefixed form (`std_math__PI`). *)
        Hashtbl.replace env.user_funcs v.cv_name.vname v.cv_def_id;
        Hashtbl.replace env.user_value_types v.cv_name.vname v.cv_ty
    | CDPrivate inner -> visit_decl inner
    | _ -> ()
  in
  List.iter visit_decl prog;
  env

let sanitize_module_name = Codegen_names.sanitize_module_name

(** Try to resolve a (module_path, func_name) pair to a builtin or
    prefixed user function. Shared logic for UFCS and import aliases. *)
let try_resolve_module_func (env : env) mod_path func_name : call_kind option =
  match Codegen_builtins.lookup mod_path func_name with
  | Some c_name -> Some (CKBuiltin c_name)
  | None -> (
      let prefixed = sanitize_module_name mod_path ^ "__" ^ func_name in
      match Hashtbl.find_opt env.user_funcs prefixed with
      | Some id -> Some (CKUser (prefixed, Some id))
      | None -> (
          (* Try __pure variant (pure/impure overloads get distinct names) *)
          let prefixed_pure = prefixed ^ "__pure" in
          match Hashtbl.find_opt env.user_funcs prefixed_pure with
          | Some id -> Some (CKUser (prefixed_pure, Some id))
          | None -> (
              (* Trait impl methods: look for Trait_method_Type pattern.
             E.g., zero from std/int → HasZero_zero_Int *)
              let suffix =
                Printf.sprintf "_%s_%s" func_name
                  (match mod_path with
                  | "std/int" -> "Int"
                  | "std/float" -> "Float"
                  | "std/bool" -> "Bool"
                  | "std/char" -> "Char"
                  | "std/string" -> "String"
                  | _ -> "")
              in
              if suffix = Printf.sprintf "_%s_" func_name then None
              else
                let matches =
                  Hashtbl.fold
                    (fun k id acc ->
                      if
                        String.length k > String.length suffix
                        &&
                        let s = String.length k - String.length suffix in
                        String.sub k s (String.length suffix) = suffix
                      then (k, id) :: acc
                      else acc)
                    env.user_funcs []
                in
                match matches with
                | [ (mangled, id) ] -> Some (CKUser (mangled, Some id))
                | _ -> None)))

(* Resolve a single call expression's call_kind.

   Resolution order:
    1. Foreign functions
    2. User-defined functions with bodies
    3. UFCS-mangled names
    4. Builtins (module-path-aware, then bare)
    5. Constructors
    6. Import aliases
    7. UFCS by first-arg type
    8. Closure (TyFunc callee)
    9. CKUnknown fallback *)

(** Map a type to candidate module paths for UFCS resolution. *)
let type_to_module_paths (ty : Ast.type_expr) : string list =
  match Codegen_types.normalize_type ty with
  | Ast.TyNamed ("String", _) -> [ "std/string"; "std/slice" ]
  | Ast.TyNamed ("StringSlice", _) -> [ "std/slice" ]
  | Ast.TyNamed ("List", _) -> [ "std/list" ]
  | Ast.TyNamed ("ParallelList", _) -> [ "std/parallel_list"; "std/list" ]
  | Ast.TyNamed ("Dict", _) -> [ "std/dict" ]
  | Ast.TyNamed ("Set", _) -> [ "std/set" ]
  | Ast.TyArray (_, dims) -> (
      match List.length dims with
      | 0 | 1 -> [ "std/tensor"; "std/vector"; "std/matrix" ]
      | 2 -> [ "std/matrix"; "std/tensor"; "std/vector" ]
      | _ -> [ "std/tensor"; "std/matrix"; "std/vector" ])
  | Ast.TyNamed ("Tensor", args)
  | Ast.TyNamed ("Vector", args)
  | Ast.TyNamed ("Matrix", args) -> (
      (* Legacy internal tensor-family names may still appear while older Core
         paths are being ported. Dispatch by rank so a 2D access like
         [get(m, row, col)] resolves through
         [std/matrix] (3-arg signature) before [std/tensor] (1D, 2-arg signature). *)
      let rank = max 0 (List.length args - 1) in
      match rank with
      | 0 | 1 -> [ "std/tensor"; "std/vector"; "std/matrix" ]
      | 2 -> [ "std/matrix"; "std/tensor"; "std/vector" ]
      | _ -> [ "std/tensor"; "std/matrix"; "std/vector" ])
  | Ast.TyNamed ("Option", _) -> [ "std/option" ]
  | Ast.TyNamed ("Result", _) -> [ "std/result" ]
  | Ast.TyNamed ("Int", _) -> [ "std/int" ]
  | Ast.TyNamed ("Int8", _) -> [ "std/int8" ]
  | Ast.TyNamed ("Int16", _) -> [ "std/int16" ]
  | Ast.TyNamed ("Int32", _) -> [ "std/int32" ]
  | Ast.TyNamed ("Int64", _) -> [ "std/int" ] (* Int64 is alias for Int *)
  | Ast.TyNamed ("Int128", _) -> [ "std/int128" ]
  | Ast.TyNamed ("UInt8", _) -> [ "std/uint8" ]
  | Ast.TyNamed ("UInt16", _) -> [ "std/uint16" ]
  | Ast.TyNamed ("UInt32", _) -> [ "std/uint32" ]
  | Ast.TyNamed ("UInt64", _) -> [ "std/uint64" ]
  | Ast.TyNamed ("UInt128", _) -> [ "std/uint128" ]
  | Ast.TyNamed ("Float", _) -> [ "std/float" ]
  | Ast.TyNamed ("Float32", _) -> [ "std/float32" ]
  | Ast.TyNamed ("Float16", _) -> [ "std/float16" ]
  | Ast.TyNamed ("Bool", _) -> [ "std/bool" ]
  | Ast.TyNamed ("Char", _) -> [ "std/char" ]
  | Ast.TyNamed ("Bytes", _) -> [ "std/bytes" ]
  | Ast.TyNamed ("Url", _) -> [ "std/net/url" ]
  | Ast.TyNamed ("Fixed", _) -> [ "std/fixed" ]
  | Ast.TyNamed ("Channel", _) -> [ "std/channel" ]
  | Ast.TyNamed ("Deque", _) -> [ "std/deque" ]
  | Ast.TyNamed ("Heap", _) -> [ "std/heap" ]
  | _ -> []

(** Resolve the module path behind a qualified call alias [M.func(args)].
    Returns [None] when [M] is not a module alias in the active import table. *)
let resolve_qualified_call_module_path (env : env) (module_path : string)
    (alias_name : string) : string option =
  match Hashtbl.find_opt env.import_aliases alias_name with
  | Some (mp, "") -> Some mp
  | _ ->
      if module_path <> "" then
        match Hashtbl.find_opt env.module_imports module_path with
        | Some mod_aliases -> (
            match Hashtbl.find_opt mod_aliases alias_name with
            | Some (mp, _) -> Some mp
            | None -> None)
        | None -> None
      else None

let try_resolve_ir_backed_std_function (mod_path : string) (field : string)
    (args : core list) : call_kind option =
  match args with
  | receiver :: _ -> (
      match
        Core_intrinsic_registry.lookup_ir_backed_std_function ~mod_path
          ~func_name:field ~arity:(List.length args) ~receiver_ty:receiver.ty
      with
      | Some intrinsic -> Some (CKIntrinsic intrinsic)
      | None -> None)
  | [] -> None

let try_resolve_module_func_call (env : env) mod_path func_name
    (args : core list) : call_kind option =
  match try_resolve_ir_backed_std_function mod_path func_name args with
  | Some kind -> Some kind
  | None -> try_resolve_module_func env mod_path func_name

(** Try to resolve a qualified module call [M.func(args)] where [M] is a
    module alias. Returns [None] if [M] is not an alias for a known module. *)
let try_resolve_qualified_call (env : env) (module_path : string)
    (alias_name : string) (field : string) (args : core list) : call_kind option
    =
  match resolve_qualified_call_module_path env module_path alias_name with
  | Some mp -> try_resolve_module_func_call env mp field args
  | None -> None

module Bound_names = Set.Make (String)

let bind_var (bound : Bound_names.t) (v : Core.var) : Bound_names.t =
  Bound_names.add v.vname bound

let bind_vars (bound : Bound_names.t) (vars : Core.var list) : Bound_names.t =
  List.fold_left bind_var bound vars

let bind_names (bound : Bound_names.t) (names : string list) : Bound_names.t =
  List.fold_left (fun acc name -> Bound_names.add name acc) bound names

let var_is_bound (bound : Bound_names.t) (v : Core.var) : bool =
  Bound_names.mem v.vname bound

(** Try to resolve a qualified module value [M.VALUE] where [M] is a
    module alias. Core lowering represents both module member access and
    ordinary field access as [CField], so this only rewrites aliases that
    are explicitly typed as [Module] at the call site and whose flattened
    global symbol exists in the program. Function-typed members stay as
    [CField] so [resolve_call_kind] can apply qualified-call builtin
    precedence before falling back to user functions. *)
let try_resolve_qualified_value ?(module_path = "") (env : env)
    (alias_name : string) (field : string) : (Core.var * Ast.type_expr) option =
  let mod_path_opt =
    if module_path = "" then
      match Hashtbl.find_opt env.import_aliases alias_name with
      | Some (mp, "") -> Some mp
      | _ -> None
    else
      match Hashtbl.find_opt env.module_imports module_path with
      | Some mod_aliases -> (
          match Hashtbl.find_opt mod_aliases alias_name with
          | Some (mp, "") -> Some mp
          | _ -> None)
      | None -> None
  in
  match mod_path_opt with
  | None -> None
  | Some mp -> (
      let prefixed = sanitize_module_name mp ^ "__" ^ field in
      match Hashtbl.find_opt env.user_value_types prefixed with
      | Some ty ->
          let vdef_id = Hashtbl.find_opt env.user_funcs prefixed in
          Some ({ (Var.named prefixed) with vdef_id }, ty)
      | None ->
          if Hashtbl.mem env.foreign_funcs prefixed then
            Some (Var.named prefixed, Ast.TyNamed ("Ptr", []))
          else None)

let resolve_call_kind ?(module_path = "") ?(bound = Bound_names.empty)
    (env : env) (callee : core) (args : core list) : call_kind =
  match callee.desc with
  | CField (obj, field) when match obj.desc with CVar _ -> true | _ -> false
    -> (
      (* Qualified module call: `M.func(args)` where `M` is a module alias.
         Also handles qualified constructors like `O.Some(v)`. Falls through
         to tuple-field / closure dispatch when [obj] is not a module alias. *)
      let alias_name = match obj.desc with CVar v -> v.vname | _ -> "" in
      let alias_is_local =
        match obj.desc with CVar v -> var_is_bound bound v | _ -> false
      in
      if alias_is_local then
        match callee.ty with Ast.TyFunc _ -> CKClosure | _ -> CKUnknown
      else if Hashtbl.mem env.constructor_names field then
        (* Qualified constructor like [O.Some(v)]. Read the def_id
           from user_funcs when present (constructor-with-fields);
           nullary constructors have no user function so None. *)
        CKUser (field, Hashtbl.find_opt env.user_funcs field)
      else
        match
          try_resolve_qualified_call env module_path alias_name field args
        with
        | Some kind -> kind
        | None -> (
            (* Not a module alias — e.g. tuple field `test_pair.1`. Fall back
                to closure dispatch on the callee's function type. *)
            match callee.ty with
            | Ast.TyFunc _ -> CKClosure
            | _ -> CKUnknown))
  | CVar v -> (
      let name = v.vname in
      if var_is_bound bound v then
        match callee.ty with Ast.TyFunc _ -> CKClosure | _ -> CKUnknown
      else
        (* 1. Foreign *)
        match Hashtbl.find_opt env.foreign_funcs name with
        | Some foreign -> CKForeign foreign
        | None -> (
            (* 1b. Imported runtime-backed std functions may already be in
             canonical prefixed form because child CVar resolution runs before
             this CCall is tagged. Resolve those through the builtin registry
             before considering std signature declarations or closure calls.
             Monomorphized bodyless std builtin declarations use their concrete
             [cf_name], so keep the collected table as the second builtin path. *)
            match
              match Codegen_builtins.lookup_prefixed name with
              | Some _ as hit -> hit
              | None -> Hashtbl.find_opt env.builtin_funcs name
            with
            | Some c_name -> CKBuiltin c_name
            | None -> (
                (* 2. User-defined. Prefer the var's [vdef_id] when present
         (A3.3 UFCS handoff), else read the def_id that [collect_env]
         stored alongside the name (A4.2). Either way [CKUser]
         receives a [Some id] so [Core_emit] can mangle via
         [mangle_by_def_id]. *)
                match Hashtbl.find_opt env.user_funcs name with
                | Some id ->
                    let chosen =
                      match v.vdef_id with Some _ as d -> d | None -> Some id
                    in
                    CKUser (name, chosen)
                | None -> (
                    (* 3. UFCS *)
                    match Codegen_names.parse_ufcs_name name with
                    | Some (mp, fn) -> (
                        match try_resolve_module_func_call env mp fn args with
                        | Some kind -> kind
                        | None -> CKUnknown)
                    | None -> (
                        (* 4. Builtins *)
                        let builtin =
                          if module_path <> "" then
                            Codegen_builtins.lookup module_path name
                          else None
                        in
                        let builtin =
                          match builtin with
                          | Some _ -> builtin
                          | None -> Codegen_builtins.lookup "" name
                        in
                        match builtin with
                        | Some c_name -> CKBuiltin c_name
                        | None -> (
                            if
                              (* 5. Constructors. Read the def_id from [user_funcs] when the
         constructor has a user C function (variant with fields);
         nullary / runtime-bypassed variants have no entry and stay [None]. *)
                              Hashtbl.mem env.constructor_names name
                            then
                              CKUser (name, Hashtbl.find_opt env.user_funcs name)
                            else
                              (* 6. Import aliases. Pick the import table by [module_path]:
         when resolving a module body, consult that module's own
         selective imports only — the main program's imports must not
         leak across module boundaries and silently rebind parameters
         that happen to match a name imported in main. *)
                              let alias =
                                if module_path = "" then
                                  Hashtbl.find_opt env.import_aliases name
                                else
                                  match
                                    Hashtbl.find_opt env.module_imports
                                      module_path
                                  with
                                  | None -> None
                                  | Some mod_aliases ->
                                      Hashtbl.find_opt mod_aliases name
                              in
                              let alias_result =
                                match alias with
                                | Some (mp, orig_name) when orig_name <> "" ->
                                    try_resolve_module_func_call env mp
                                      orig_name args
                                | _ -> None
                              in
                              match alias_result with
                              | Some kind -> kind
                              | None -> (
                                  (* 7. UFCS by first-arg type *)
                                  let ufcs_result =
                                    match args with
                                    | first_arg :: _ ->
                                        let paths =
                                          type_to_module_paths first_arg.ty
                                        in
                                        let rec try_paths = function
                                          | [] -> None
                                          | mp :: rest -> (
                                              match
                                                try_resolve_module_func_call env
                                                  mp name args
                                              with
                                              | Some kind -> Some kind
                                              | None -> try_paths rest)
                                        in
                                        try_paths paths
                                    | [] -> None
                                  in
                                  match ufcs_result with
                                  | Some kind -> kind
                                  | None -> (
                                      (* Trait-method dispatch used to live here as a suffix-scan of
         [env.user_funcs] for [_<method>_<type>] — a single step that
         conflated impl lookup with name mangling. It's been moved into
         the [Core_trait_resolve] pass (Phase 3.1), which runs between
         [Core_mono] and this resolver. By the time we get here, trait
         calls have already been rewritten to their mangled form and
         flow through the normal [user_funcs] lookup above. *)
                                      (* 8. Bare [CVar v] with [TyFunc] type that didn't resolve above.
         Two distinct shapes hide here:

         (a) A type-dispatched stdlib builtin like [sum]/[product] —
             declared as a generic signature without a body, not in
             user_funcs, not in the C builtin table. [Core_specialize]
             picks these up only when the kind is still [CKUnknown].

         (b) A local parameter with function type (e.g. [f: () -> Void]
             inside [measure_memory(f)]) — must emit as a closure call.

         We distinguish by whether the name appears in an import table:
         an imported name can't also be a local binding, so it's (a). *)
                                      let is_imported =
                                        Hashtbl.mem env.import_aliases name
                                        || module_path <> ""
                                           &&
                                           match
                                             Hashtbl.find_opt env.module_imports
                                               module_path
                                           with
                                           | Some mod_aliases ->
                                               Hashtbl.mem mod_aliases name
                                           | None -> false
                                      in
                                      let is_bitwise_op =
                                        match name with
                                        | "bit_and" | "bit_or" | "bit_xor"
                                        | "bit_not" | "shift_left"
                                        | "shift_right" ->
                                            true
                                        | _ -> false
                                      in
                                      if is_imported || is_bitwise_op then
                                        CKUnknown
                                      else
                                        match callee.ty with
                                        | Ast.TyFunc _ -> CKClosure
                                        | _ -> CKUnknown))))))))
  | _ -> ( match callee.ty with Ast.TyFunc _ -> CKClosure | _ -> CKUnknown)

(** Rewrite a bare [CVar] that refers to a globally-imported value (e.g.
    [PI] from [import: math: PI]) to its prefixed module form
    ([std_math__PI]). Only applies when the name resolves to an imported
    non-function symbol — function names are handled per-call in
    [resolve_call_kind].

    The import table is chosen by [module_path]: when resolving a module's
    own body we use [module_imports[module_path]] only; we must not fall
    back to the main program's [import_aliases] or bare identifiers that
    happen to shadow a main-program import (e.g. a parameter named [field]
    inside [std/csv] when the main program imports [codec.field]) would be
    silently rewritten to the prefixed name. *)
let rewrite_imported_var ?(module_path = "") (env : env) (v : Core.var) :
    Core.var =
  let try_prefix (mp, orig) =
    let prefixed = sanitize_module_name mp ^ "__" ^ orig in
    if
      Hashtbl.mem env.user_funcs prefixed
      || Hashtbl.mem env.foreign_funcs prefixed
    then Some prefixed
    else None
  in
  (* Prelude-registered bare-name builtins (e.g. [length], [to_string],
     [equals], [min]) are type-dispatched sentinels — [Core_specialize]
     picks the concrete intrinsic based on the call's argument type.
     If the user imports a same-named function from some module (e.g.
     [import: tensor: length]), don't rewrite the bare call to the
     imported module's prefixed user function: that would bypass the
     sentinel and force a single type's impl on every call site, even
     ones whose arg type doesn't match. Leave the bare name alone so
     [resolve_call_kind]'s builtin step finds the sentinel. *)
  let is_prelude_builtin name = Codegen_builtins.lookup "" name <> None in
  let alias =
    if module_path = "" then Hashtbl.find_opt env.import_aliases v.vname
    else
      match Hashtbl.find_opt env.module_imports module_path with
      | None -> None
      | Some mod_aliases -> Hashtbl.find_opt mod_aliases v.vname
  in
  match alias with
  | Some (mp, orig) when orig <> "" && not (is_prelude_builtin v.vname) -> (
      match try_prefix (mp, orig) with
      | Some prefixed -> { v with vname = prefixed }
      | None -> v)
  | _ -> v

(* Bare value references are rewritten only when they are not shadowed by a
   Core-local binder. Function calls use [resolve_call_kind] with the same
   bound-name set so imported/top-level functions cannot override parameters,
   locals, loop variables, or pattern bindings. *)

(** Walk a single Core expression and rewrite [CCall] nodes plus imported
    [CVar] references. *)
let rec resolve_expr ?(module_path = "") ?(bound = Bound_names.empty)
    (env : env) (e : core) : core =
  let resolve_same = resolve_expr ~module_path ~bound env in
  let resolve_with bound = resolve_expr ~module_path ~bound env in
  let resolve_ctree bound tree =
    let rec go bound = function
      | CTLeaf { ct_bindings; ct_body } ->
          let body_bound =
            List.fold_left (fun acc (v, _) -> bind_var acc v) bound ct_bindings
          in
          CTLeaf { ct_bindings; ct_body = resolve_with body_bound ct_body }
      | CTFail -> CTFail
      | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
          CTSwitchTag
            {
              cts_scrut;
              cts_cases =
                List.map
                  (fun (tag, subtree) -> (tag, go bound subtree))
                  cts_cases;
              cts_default = Option.map (go bound) cts_default;
            }
      | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
          CTSwitchLit
            {
              ctl_scrut;
              ctl_cases =
                List.map
                  (fun (lit, subtree) -> (lit, go bound subtree))
                  ctl_cases;
              ctl_default = go bound ctl_default;
            }
      | CTSwitchLen
          { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default } ->
          CTSwitchLen
            {
              ctl_len_scrut;
              ctl_len_cases =
                List.map
                  (fun (len, subtree) -> (len, go bound subtree))
                  ctl_len_cases;
              ctl_len_geq =
                Option.map
                  (fun (len, subtree) -> (len, go bound subtree))
                  ctl_len_geq;
              ctl_len_default = Option.map (go bound) ctl_len_default;
            }
    in
    go bound tree
  in
  match e.desc with
  | CCall (CKUnknown, callee, args) ->
      let callee' = resolve_same callee in
      let args' = List.map resolve_same args in
      let kind = resolve_call_kind ~module_path ~bound env callee' args' in
      { e with desc = CCall (kind, callee', args') }
  | CCall (kind, callee, args) ->
      {
        e with
        desc = CCall (kind, resolve_same callee, List.map resolve_same args);
      }
  | CField ({ desc = CVar alias; ty = Ast.TyNamed ("Module", []); _ }, field)
    when (not (var_is_bound bound alias))
         &&
         match Codegen_types.normalize_type e.ty with
         | Ast.TyFunc _ -> false
         | _ -> true -> (
      match try_resolve_qualified_value ~module_path env alias.vname field with
      | Some (v, ty) -> { e with desc = CVar v; ty }
      | None ->
          let e' = map_children resolve_same e in
          e')
  | CVar v when var_is_bound bound v -> e
  | CVar v ->
      let v' = rewrite_imported_var ~module_path env v in
      (* Populate [vdef_id] for function-typed references only.
         Value-typed references stay untouched: if they are globals, their
         emitted C name is already the flattened global name; if they are
         locals, the scoped check above prevents import/global rewrites. *)
      let v' =
        match (v'.vdef_id, Codegen_types.normalize_type e.ty) with
        | None, Ast.TyFunc _ -> (
            match Hashtbl.find_opt env.user_funcs v'.vname with
            | Some id -> { v' with vdef_id = Some id }
            | None -> v')
        | _ -> v'
      in
      { e with desc = CVar v' }
  | CLet (binding, body) ->
      let rhs' = resolve_same binding.bind_rhs in
      let body' = resolve_with (bind_var bound binding.bind_var) body in
      { e with desc = CLet ({ binding with bind_rhs = rhs' }, body') }
  | CBorrowLet (binding, body) ->
      let rhs' = resolve_same binding.borrow_rhs in
      let body' = resolve_with (bind_var bound binding.borrow_var) body in
      { e with desc = CBorrowLet ({ binding with borrow_rhs = rhs' }, body') }
  | CTensorRawViewLet (binding, body) ->
      let source' = resolve_same binding.trv_source in
      let body' = resolve_with (bind_var bound binding.trv_var) body in
      {
        e with
        desc = CTensorRawViewLet ({ binding with trv_source = source' }, body');
      }
  | CLambda lam ->
      let lam_bound =
        List.fold_left (fun acc (v, _) -> bind_var acc v) bound lam.lam_params
      in
      {
        e with
        desc =
          CLambda { lam with lam_body = resolve_with lam_bound lam.lam_body };
      }
  | CFor (binder, iter, body) ->
      let iter' = resolve_same iter in
      let body' = resolve_with (bind_var bound binder.loop_var) body in
      { e with desc = CFor (binder, iter', body') }
  | CMatchArms (scrut, arms) ->
      let scrut' = resolve_same scrut in
      let arms' =
        List.map
          (fun (pat, body) ->
            let arm_bound = bind_names bound (Core.pat_vars pat) in
            (pat, resolve_with arm_bound body))
          arms
      in
      { e with desc = CMatchArms (scrut', arms') }
  | CMatch (scrut, tree) ->
      { e with desc = CMatch (resolve_same scrut, resolve_ctree bound tree) }
  | CConcurrent block ->
      let conc_bindings =
        List.map
          (fun b -> { b with cb_rhs = resolve_same b.cb_rhs })
          block.conc_bindings
      in
      let body_bound =
        List.fold_left
          (fun acc b -> bind_var acc b.cb_var)
          bound block.conc_bindings
      in
      {
        e with
        desc =
          CConcurrent
            {
              block with
              conc_bindings;
              conc_body = resolve_with body_bound block.conc_body;
              conc_timeout = Option.map resolve_same block.conc_timeout;
            };
      }
  | CConcurrentFor cf ->
      {
        e with
        desc =
          CConcurrentFor
            {
              cf with
              cf_iter = resolve_same cf.cf_iter;
              cf_body = resolve_with (bind_var bound cf.cf_var) cf.cf_body;
              cf_timeout = Option.map resolve_same cf.cf_timeout;
            };
      }
  | CListHandoff handoff ->
      let body_bound =
        bind_vars bound
          [
            handoff.lh_source_var;
            handoff.lh_result_var;
            handoff.lh_len_var;
            handoff.lh_out_var;
          ]
      in
      {
        e with
        desc =
          CListHandoff
            {
              handoff with
              lh_source = resolve_same handoff.lh_source;
              lh_capacity = resolve_same handoff.lh_capacity;
              lh_body = resolve_with body_bound handoff.lh_body;
            };
      }
  | CTailrecLoop (TailrecUnmanagedLoop loop) ->
      let loop_bound =
        List.fold_left
          (fun acc p -> bind_var acc p.cp_name)
          bound loop.tul_params
      in
      {
        e with
        desc =
          CTailrecLoop
            (TailrecUnmanagedLoop
               { loop with tul_body = resolve_with loop_bound loop.tul_body });
      }
  | CTailrecLoop (TailrecListSpreadLoop loop) ->
      let loop_bound =
        List.fold_left
          (fun acc p -> bind_var acc p.cp_name)
          (bind_var bound loop.tls_cursor_var)
          loop.tls_params
      in
      {
        e with
        desc =
          CTailrecLoop
            (TailrecListSpreadLoop
               { loop with tls_body = resolve_with loop_bound loop.tls_body });
      }
  | _ -> map_children resolve_same e

(** Rewrite [CCall]s inside a single function body. *)
let resolve_func (env : env) (f : core_func) : core_func =
  match f.cf_body with
  | None -> f
  | Some body ->
      let module_path = Option.value f.cf_module ~default:"" in
      let param_bound =
        List.fold_left
          (fun acc (p : core_param) -> bind_var acc p.cp_name)
          Bound_names.empty f.cf_params
      in
      let param_bound =
        match f.cf_kind with
        | CFClosureBody abi ->
            let with_abi_params =
              List.fold_left
                (fun acc (v, _) -> bind_var acc v)
                param_bound abi.ca_params
            in
            List.fold_left
              (fun acc (name, _) -> Bound_names.add name acc)
              with_abi_params abi.ca_captures
        | _ -> param_bound
      in
      {
        f with
        cf_body = Some (resolve_expr ~module_path ~bound:param_bound env body);
      }

(** Rewrite [CCall]s inside a global variable's initializer. *)
let resolve_var (env : env) (v : core_var) : core_var =
  let module_path = Option.value v.cv_module ~default:"" in
  { v with cv_init = resolve_expr ~module_path env v.cv_init }

(** Rewrite [CCall]s inside an impl block's methods. *)
let resolve_impl (env : env) (i : core_impl) : core_impl =
  { i with ci_methods = List.map (resolve_func env) i.ci_methods }

(** Rewrite a single declaration. *)
let rec resolve_decl (env : env) (d : core_decl) : core_decl =
  let desc' =
    match d.cd_desc with
    | CDFunc f -> CDFunc (resolve_func env f)
    | CDVar v -> CDVar (resolve_var env v)
    | CDImpl i -> CDImpl (resolve_impl env i)
    | CDTrait _ as other -> other (* no expressions; defaults live on AST *)
    | CDPrivate inner -> CDPrivate (resolve_decl env inner)
    | (CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _) as other -> other
  in
  { d with cd_desc = desc' }

(** Walk a program, tagging every [CCall] with a concrete [call_kind]
    where the callee can be resolved. Unresolvable calls stay as
    [CKUnknown] and are handled by downstream passes. *)
let resolve_program ?(import_aliases = Hashtbl.create 0)
    ?(module_imports = Hashtbl.create 0) (prog : core_program) : core_program =
  let env = collect_env ~import_aliases ~module_imports prog in
  List.map (resolve_decl env) prog
