(** Trait-method resolution pass (Phase 3.1).

    Walks a [core_program] post-monomorphization and rewrites [CCall]
    callees whose bare name is a trait method to the matching impl's
    mangled name (e.g. [Trait_method_Type]). Runs after [Core_mono] (so
    receiver types are concrete) and before [Core_resolve] (so the
    rewritten name flows through regular name-lookup).

    {1 Why a dedicated pass}

    Before Phase 3.1, [Core_resolve.resolve_call_kind]'s step 7b scanned
    [env.user_funcs] for any key whose suffix matched [_<method>_<type>]
    and used the longest-match. That logic worked for the happy path but
    conflated three concerns (name mangling, impl lookup, diagnostic
    generation) inside the resolver's dispatch chain, produced no
    structured error when a trait method was called without an impl in
    scope, and had no home for Phase 3.2's operator-overload rewrites to
    slot into. Extracting this pass gives those rewrites a principled
    home and lets [Core_resolve] shrink back to pure name-lookup.

    {1 Algorithm}

    1. Walk the program once collecting [(method_name, type_name) →
       mangled_name] from [CDImpl] nodes (each impl method becomes
       [Trait_method_Type]).
    2. Walk the program again. For each [CCall] whose callee is
       [CVar { vname = bare_name; _ }] and whose first arg has a type of
       [TyNamed (type_name, _)], look up [(bare_name, type_name)] in the
       registry. On hit, rewrite the callee's name to the mangled form.
    3. Before treating a bare name as trait dispatch, consult the same
       per-module import tables used by [Core_resolve]. A direct ordinary
       function import such as [int { is_even }] must shadow an unrelated
       trait method named [is_even]; otherwise a trait declared elsewhere
       in the combined program would hijack the imported function call.
    4. Leave non-matching calls alone; [Core_resolve] handles every other
       dispatch kind (foreign / user / builtin / constructor / UFCS / …).

    {1 Operator overloading (Phase 3.2)}

    Same pass also rewrites [CBin] / [CUn] nodes whose operand type
    has a matching impl of the operator's trait. The mapping:

    {v
    CBin (Add, a, b) → CCall Addable.add  (if impl exists for a.ty)
    CBin (Sub, _)    → Subtractable.subtract
    CBin (Mul, _)    → Multipliable.multiply
    CBin (Div, _)    → Divisible.divide
    CBin (Mod, _)    → Modulable.remainder
    CBin (Eq, _)     → Equatable.equals
    CBin (Ne, _)     → Equatable.not_equals
    CBin (Lt, _)     → Orderable.less_than
    CBin (Gt, _)     → Orderable.greater_than
    CBin (Le, _)     → Orderable.less_than_or_equal
    CBin (Ge, _)     → Orderable.greater_than_or_equal
    CUn  (Neg, x)    → Negatable.negate
    v}

    Primitives keep the direct-operator fast path because they have no
    [CDImpl] — the "impl exists" check naturally filters them out.
    Enum types similarly route to their int-tag comparison via the
    direct path. [CUn (Not, _)] is logical-negation on [Bool] and has
    no trait mapping. Short-circuit [CLog (And | Or, _, _)] is
    deliberately excluded — short-circuiting is semantic, not a
    method-call target.

    {1 Diagnostics}

    On a [CCall] where the callee's bare name IS a declared trait
    method AND at least one other type has an impl of that method
    (i.e. [impls_by_method[name] <> []]) AND the first-arg receiver
    type is a concrete [TyNamed] with no matching impl of its own,
    this pass raises a structured [Core_error] with the message "no
    impl of [method] for type [Type] in scope", and a Levenshtein
    suggestion sourced from [impls_by_method].

    The "at least one other type has an impl" guard is what makes the
    diagnostic safe: trait methods with no impls anywhere in the
    program are by definition handled by some downstream mechanism
    ([Core_specialize]'s type dispatch for bitwise ops and primitives,
    [Codegen_builtins]'s UFCS lookup for prelude shadows, …), so
    firing the error on them would be a false positive. The
    diagnostic is targeted at user code where someone has defined a
    trait, implemented it for [Dog], and then called the method on
    [Sheep] without writing a [Sheep] impl.

    {1 What this pass deliberately does NOT do (yet)}

    - Stdlib prelude-shadow dispatch (e.g., [to_string] on [Int] →
      [blorp_to_string]). Those remain in [Core_specialize]'s hardcoded
      type-dispatch tables.
    - Operator overloading. Phase 3.2 will lower [CBin (Add, a, b)] on
      non-primitive operand types into [CCall (Addable.add, …)] which
      this pass then resolves — but the lowering itself isn't here. *)

open Core
module StringSet = Set.Make (String)

type impl_key = string * string (* (method_name, type_name) *)

type direct_function = {
  df_params : Ast.type_expr list;
  df_type_params : Ast.type_param_decl list;
}

type registry = {
  impls : (impl_key, string) Hashtbl.t;
  shadowed_names : (string, string list) Hashtbl.t;
  direct_functions : (string * string, direct_function list) Hashtbl.t;
      (** [(module_path, source_name)] entries for ordinary module functions,
        carrying parameter types. Used with import tables to distinguish
        direct function imports from imported trait-method names before
        call-kind resolution runs. *)
  import_aliases : (string, string * string) Hashtbl.t;
  module_imports : (string, (string, string * string) Hashtbl.t) Hashtbl.t;
  trait_methods : (string, unit) Hashtbl.t;
      (** Names that appear as [ctm_name] on any [CDTrait] — the set of
        bare identifiers that look like a trait-method call and are
        therefore eligible for the "no impl" diagnostic. *)
  static_self_methods : (string, unit) Hashtbl.t;
      (** Zero-argument trait methods whose return type is [Self].
        Unlike receiver-style methods, these dispatch from the expected
        return type after monomorphization. Keeping this separate from
        [trait_methods] avoids guessing that every nullary trait method
        should use return-type dispatch. *)
  impls_by_method : (string, string list) Hashtbl.t;
      (** [method_name → types that have an impl for this method], used
        to produce a Levenshtein "did you mean" suggestion when a
        trait-method call has no matching impl. *)
}
(** State needed to resolve a program: [impls] is the [(method, type) →
    mangled_name] registry; [shadowed_names] maps a bare name to the set
    of first-param type-heads for which a top-level [CDFunc] already
    handles the call.

    {b Why the map is per-first-param-type and not just per-name}: a name
    like [to_string] can be shadowed by [pure func to_string(val:
    JsonValue)] in [std/json/value.brp] AND legitimately need trait
    dispatch for [to_string((1, 2))] where the first-arg is a tuple. A
    plain name-level skip would conflate the two and leave the tuple call
    unresolved. Recording the shadow's first-param type-head lets
    [resolve_expr] skip the rewrite only when the call's first-arg type
    matches that same head, letting unrelated receiver types route through
    the impl registry uniformly.

    Primitive prelude shadows like [to_string] on [Int] are NOT caught
    here — they're [CKBuiltin] dispatches registered in [Env_builtins],
    not [CDFunc] nodes, and by the time this pass runs module prefixing
    has already rewritten stdlib function names to
    [std_<module>__<name>]. The load-bearing guard for those cases is the
    self-recursion check in [resolve_expr] (see there). *)

(** Build the trait-resolve registry from a program. Walks once:

    - Every [CDImpl] contributes a [(method_name, concrete_type_key) →
      Trait_method_Type_Key] entry (skipping impls whose [ci_for_type] still
      carries a type variable — those appear only in generic-parent
      form and their concrete mono specializations re-register), plus a
      [method_name → type_name] entry for [impls_by_method].
    - Every module [CDFunc] contributes [(module_path, source_name)] to
      [direct_functions], so imported ordinary functions can be recognized
      before [Core_resolve] has rewritten the call.
    - Every [CDTrait] contributes its method names to [trait_methods].
    - Every [CDFunc] contributes its bare name to [shadowed_names]
      (see [registry] for why this catches less than it looks like). *)
let collect_registry ~(import_aliases : (string, string * string) Hashtbl.t)
    ~(module_imports : (string, (string, string * string) Hashtbl.t) Hashtbl.t)
    (prog : core_program) : registry =
  let impls = Hashtbl.create 32 in
  let shadowed_names = Hashtbl.create 32 in
  let direct_functions = Hashtbl.create 32 in
  let trait_methods = Hashtbl.create 32 in
  let static_self_methods = Hashtbl.create 8 in
  let impls_by_method = Hashtbl.create 32 in
  let add_impl_type (method_name : string) (type_name : string) =
    let existing =
      try Hashtbl.find impls_by_method method_name with Not_found -> []
    in
    if not (List.mem type_name existing) then
      Hashtbl.replace impls_by_method method_name (type_name :: existing)
  in
  let add_direct_function_entry module_path source_name (f : core_func) =
    let entry =
      {
        df_params = List.map (fun (p : core_param) -> p.cp_ty) f.cf_params;
        df_type_params = f.cf_type_params;
      }
    in
    let key = (module_path, source_name) in
    let existing =
      Hashtbl.find_opt direct_functions key |> Option.value ~default:[]
    in
    Hashtbl.replace direct_functions key (entry :: existing)
  in
  let add_direct_function (f : core_func) =
    match f.cf_module with
    | None -> add_direct_function_entry "" f.cf_name f
    | Some module_path ->
        let prefix = Codegen_names.sanitize_module_name module_path ^ "__" in
        if String.starts_with ~prefix f.cf_name then begin
          let source_name =
            String.sub f.cf_name (String.length prefix)
              (String.length f.cf_name - String.length prefix)
          in
          add_direct_function_entry module_path source_name f;
          let pure_suffix = "__pure" in
          if String.ends_with ~suffix:pure_suffix source_name then
            let base =
              String.sub source_name 0
                (String.length source_name - String.length pure_suffix)
            in
            add_direct_function_entry module_path base f
        end
        else add_direct_function_entry module_path f.cf_name f
  in
  let rec visit_decl (d : core_decl) =
    match d.cd_desc with
    | CDImpl i when not (Codegen_types.has_type_vars i.ci_for_type) -> (
        match Codegen_types.type_key_for_impl i.ci_for_type with
        | Some type_name ->
            List.iter
              (fun (m : core_func) ->
                let mangled =
                  Printf.sprintf "%s_%s_%s" i.ci_trait m.cf_name type_name
                in
                Hashtbl.replace impls (m.cf_name, type_name) mangled;
                add_impl_type m.cf_name type_name)
              i.ci_methods
        | None ->
            (* Shape has no registered impl-lookup key (function type,
                range, etc.). Skip silently — these impls aren't
                dispatchable through the trait machinery today. *)
            ())
    | CDImpl _ -> ()
    | CDTrait t ->
        List.iter
          (fun (m : core_trait_method) ->
            Hashtbl.replace trait_methods m.ctm_name ();
            match (m.ctm_params, m.ctm_return_ty) with
            | [], Some Ast.TySelf ->
                Hashtbl.replace static_self_methods m.ctm_name ()
            | _ -> ())
          t.ct_methods
    | CDFunc f -> (
        add_direct_function f;
        (* Record the first-param type-head (if any) as a shadow
           for this name. Zero-param CDFuncs don't shadow anything —
           their calls take no args and never reach the rewrite path
           in [resolve_expr] in the first place. *)
        match f.cf_params with
        | [] -> ()
        | first :: _ ->
            let shadow_keys =
              let concrete =
                if Codegen_types.has_type_vars first.cp_ty then None
                else Codegen_types.type_key_for_impl first.cp_ty
              in
              let head =
                match Codegen_types.normalize_type first.cp_ty with
                | Ast.TyNamed (n, _) when not (Types.is_type_param_name n) ->
                    Some n
                | Ast.TyTuple ts ->
                    Some (Printf.sprintf "Tuple%d" (List.length ts))
                | _ -> None
              in
              [ concrete; head ] |> List.filter_map (fun x -> x)
            in
            let existing =
              try Hashtbl.find shadowed_names f.cf_name with Not_found -> []
            in
            let merged =
              List.fold_left
                (fun acc key -> if List.mem key acc then acc else key :: acc)
                existing shadow_keys
            in
            Hashtbl.replace shadowed_names f.cf_name merged)
    | CDPrivate inner -> visit_decl inner
    | _ -> ()
  in
  List.iter visit_decl prog;
  {
    impls;
    shadowed_names;
    direct_functions;
    import_aliases;
    module_imports;
    trait_methods;
    static_self_methods;
    impls_by_method;
  }

let import_table_for_module (reg : registry) (module_path : string option) :
    (string, string * string) Hashtbl.t option =
  match module_path with
  | None -> Some reg.import_aliases
  | Some mp -> Hashtbl.find_opt reg.module_imports mp

(** The typed frontend already accepted this call. Here we only need enough
    shape checking to avoid suppressing real trait dispatch because an
    unrelated same-named ordinary function exists in the same module. *)
let direct_function_matches_args (entry : direct_function) (args : core list) :
    bool =
  List.length entry.df_params = List.length args
  && List.for_all2
       (fun param arg ->
         Types.types_compatible
           ~type_params:(Ast.type_param_names entry.df_type_params)
           param arg.ty)
       entry.df_params args

let callee_type_matches_args (callee : core) (args : core list) : bool =
  match callee.ty with
  | Ast.TyFunc { params; _ } ->
      List.length params = List.length args
      && List.for_all2
           (fun param arg -> Types.types_compatible param arg.ty)
           params args
  | _ -> false

(** True when [name] is lexically bound by a direct ordinary function import
    in [module_path]'s scope. Trait-method imports intentionally do not count:
    they have no module [CDFunc] target and must remain eligible for trait
    dispatch. *)
let is_direct_imported_function (reg : registry) (module_path : string option)
    (callee : core) (name : string) (args : core list) : bool =
  match import_table_for_module reg module_path with
  | None -> false
  | Some imports -> (
      match Hashtbl.find_opt imports name with
      | Some (imported_module, original_name) when original_name <> "" -> (
          match
            Hashtbl.find_opt reg.direct_functions
              (imported_module, original_name)
          with
          | Some candidates ->
              List.exists
                (fun entry -> direct_function_matches_args entry args)
                candidates
          | None ->
              Codegen_builtins.lookup imported_module original_name <> None
              && callee_type_matches_args callee args)
      | _ -> false)

let is_local_direct_function (reg : registry) (module_path : string option)
    (name : string) (args : core list) : bool =
  let key = (Option.value module_path ~default:"", name) in
  match Hashtbl.find_opt reg.direct_functions key with
  | Some candidates ->
      List.exists
        (fun entry -> direct_function_matches_args entry args)
        candidates
  | None -> false

let is_direct_ufcs_function (reg : registry) (module_path : string)
    (name : string) (args : core list) : bool =
  match Hashtbl.find_opt reg.direct_functions (module_path, name) with
  | Some candidates ->
      List.exists
        (fun entry -> direct_function_matches_args entry args)
        candidates
  | None -> Codegen_builtins.lookup module_path name <> None

(** Bare method name for each overloadable binary operator. [None] for
    [Ast.binop] shapes not routed through traits (there are none today —
    every [binop] variant is overloadable — but the [option] return
    keeps the site uniform with [unop_method] below). *)
let binop_method : Ast.binop -> string option = function
  | Ast.Add -> Some "add"
  | Ast.Sub -> Some "subtract"
  | Ast.Mul -> Some "multiply"
  | Ast.Div -> Some "divide"
  | Ast.Mod -> Some "remainder"
  | Ast.Eq -> Some "equals"
  | Ast.Ne -> Some "not_equals"
  | Ast.Lt -> Some "less_than"
  | Ast.Gt -> Some "greater_than"
  | Ast.Le -> Some "less_than_or_equal"
  | Ast.Ge -> Some "greater_than_or_equal"

(** Bare method name for overloadable unary operators. [Not] is
    logical-negation on [Bool] and has no trait mapping today. *)
let unop_method : Ast.unop -> string option = function
  | Ast.Neg -> Some "negate"
  | Ast.Not -> None

(** Render a type to its concrete impl-dispatch key, if any.
    Used as the impl-lookup key for trait-method calls and operator
    overloads.

    Parameterized types include their concrete arguments here
    ([Result_Int_String], [Tuple2_Int_Int]) so separate
    monomorphized impls do not collide. A trait-method call whose
    receiver is still a type variable post-mono is either inside an
    unmonomorphized generic parent (expected — we ignore, the
    monomorphized copy will re-resolve) or a specialize miss (a
    separate bug that the TyVar-leak invariant catches). *)
let type_name_of_ty (ty : Ast.type_expr) : string option =
  Codegen_types.type_key_for_impl (Types.Dim.lift_to_int ty)

let first_arg_type_name (args : core list) : string option =
  match args with first :: _ -> type_name_of_ty first.ty | [] -> None

let first_arg_type_head (args : core list) : string option =
  match args with
  | first :: _ -> (
      match Codegen_types.normalize_type first.ty with
      | Ast.TyNamed (n, _) when not (Types.is_type_param_name n) -> Some n
      | Ast.TyTuple ts -> Some (Printf.sprintf "Tuple%d" (List.length ts))
      | _ -> None)
  | [] -> None

let static_self_return_type_name (reg : registry) (method_name : string)
    (return_ty : Ast.type_expr) : string option =
  if Hashtbl.mem reg.static_self_methods method_name then
    type_name_of_ty return_ty
  else None

let fallback_no_impl_hint method_name type_name candidates =
  match candidates with
  | [] ->
      Printf.sprintf
        "no type in scope implements `%s`. Define an `implements <trait> for \
         %s:` block with a `%s` method."
        method_name type_name method_name
  | _ ->
      Printf.sprintf
        "types with an `%s` impl in scope: %s. Add `implements <trait> for \
         %s:` to extend it."
        method_name
        (String.concat ", " (List.sort compare candidates))
        type_name

let no_impl_hint method_name type_name candidates =
  try
    Compiler_blorp_bridge.render_core_trait_resolve_no_impl_hint ~method_name
      ~type_name ~candidates
  with Invalid_argument _ ->
    fallback_no_impl_hint method_name type_name candidates

(** Emit a structured "no impl of X for Y in scope" error. Hint text is
    rendered by Blorp so the pipeline's user-facing diagnostic policy moves
    with the self-hosted compiler surface. Raises via [Core_error.errorf]. *)
let error_no_impl (reg : registry) (loc : Ast.loc) (method_name : string)
    (type_name : string) : 'a =
  let candidates =
    try Hashtbl.find reg.impls_by_method method_name with Not_found -> []
  in
  let hint = no_impl_hint method_name type_name candidates in
  Core_error.errorf (Core_error.Stage Core_stage.TraitResolve) loc ~hint
    "no impl of `%s` for type `%s` in scope" method_name type_name

let has_operator_fast_path (ty : Ast.type_expr) : bool =
  Type_metadata.has_native_operator_fast_path_type ty

let has_to_string_builtin_fallback (ty : Ast.type_expr) : bool =
  Type_metadata.has_builtin_to_string_fallback_type ty

(** Rewrite a [CBin] / [CUn] to a [CCall] targeting the impl's method
    when an impl is registered for the operand's concrete type. Returns
    [None] to signal "leave the node alone" (primitive fast-path, no
    impl, type variable, etc.) — the common case. *)
let try_rewrite_operator (reg : registry) (e : core) (method_name : string)
    (operands : core list) : core option =
  match operands with
  | first :: _ when not (has_operator_fast_path first.ty) -> (
      match type_name_of_ty first.ty with
      | Some type_name -> (
          match Hashtbl.find_opt reg.impls (method_name, type_name) with
          | Some mangled ->
              let callee =
                {
                  desc = CVar (Var.named mangled);
                  ty = Ast.TyNamed ("", []);
                  loc = e.loc;
                }
              in
              Some { e with desc = CCall (CKUnknown, callee, operands) }
          | None -> None)
      | None -> None)
  | _ -> None

(** Rewrite one expression bottom-up: recursive via [map_children], then
    pattern-match on the current node.

    [CCall (CKUnknown, CVar bare_name, (arg0 :: _))] rewrites to the
    impl mangled name only when:
    - [bare_name] is NOT itself a top-level user function (to avoid
      clobbering the prelude shadow; see [collect_registry]), and
    - the registry has an impl for [(bare_name, type_name(arg0))], and
    - the target mangled name is NOT the name of the enclosing
      function — a self-match would turn e.g. the stdlib's
      [impl Stringable for Int] body [val.to_string()] into infinite
      recursion. Those primitive-type shadow impls legitimately
      delegate to [Core_specialize]'s hardcoded dispatch (it rewrites
      [to_string(Int)] → [blorp_to_string]), so we leave them alone.

    When the bare name IS a trait method, the receiver type is a
    concrete [TyNamed], and NO impl is in the registry, we fire the
    "no impl" diagnostic — unless [Codegen_builtins.lookup] covers the
    name (in which case [Core_specialize] handles it downstream).

    [CBin] / [CUn] are rewritten via [try_rewrite_operator] when the
    operand type has an impl of the operator's trait method (Phase 3.2
    operator overloading). Primitives have no [CDImpl], so the lookup
    misses and the node stays as-is for the fast path. *)
let rec resolve_expr (reg : registry) (module_path : string option)
    (in_func : string option) (shadowed_locals : StringSet.t) (e : core) : core
    =
  let e =
    match e.desc with
    | CResourceScope s ->
        let rs_acquire =
          resolve_expr reg module_path in_func shadowed_locals s.rs_acquire
        in
        let shadowed_locals' = StringSet.add s.rs_var.vname shadowed_locals in
        let rs_body =
          resolve_expr reg module_path in_func shadowed_locals' s.rs_body
        in
        let rs_cleanup =
          resolve_expr reg module_path in_func shadowed_locals' s.rs_cleanup
        in
        {
          e with
          desc = CResourceScope { s with rs_acquire; rs_body; rs_cleanup };
        }
    | _ -> map_children (resolve_expr reg module_path in_func shadowed_locals) e
  in
  match e.desc with
  | CCall (CKBuiltin "blorp_to_string", callee, [ arg ]) -> (
      match type_name_of_ty arg.ty with
      | Some type_name -> (
          match Hashtbl.find_opt reg.impls ("to_string", type_name) with
          | Some mangled ->
              if Some mangled = in_func && has_to_string_builtin_fallback arg.ty
              then e
              else if has_to_string_builtin_fallback arg.ty then e
              else
                let callee' = { callee with desc = CVar (Var.named mangled) } in
                { e with desc = CCall (CKUnknown, callee', [ arg ]) }
          | None -> e)
      | None -> e)
  | CCall ((CKUnknown | CKSelectedDirect _), callee, args) -> (
      match callee.desc with
      | CVar v -> (
          if StringSet.mem v.vname shadowed_locals then e
          else
            let ufcs_target = Codegen_names.parse_ufcs_name v.vname in
            let method_name =
              match ufcs_target with Some (_, name) -> name | None -> v.vname
            in
            let is_direct_call_target () =
              match ufcs_target with
              | Some (target_module, target_name) ->
                  is_direct_ufcs_function reg target_module target_name args
              | None ->
                  is_direct_imported_function reg module_path callee v.vname
                    args
                  || is_local_direct_function reg module_path v.vname args
            in
            let try_static_self_dispatch () =
              match args with
              | [] -> (
                  if is_direct_call_target () then e
                  else
                    match static_self_return_type_name reg method_name e.ty with
                    | Some type_name -> (
                        match
                          Hashtbl.find_opt reg.impls (method_name, type_name)
                        with
                        | Some mangled ->
                            let callee' =
                              { callee with desc = CVar (Var.named mangled) }
                            in
                            { e with desc = CCall (CKUnknown, callee', args) }
                        | None ->
                            let has_other_impls =
                              match
                                Hashtbl.find_opt reg.impls_by_method method_name
                              with
                              | Some (_ :: _) -> true
                              | _ -> false
                            in
                            if
                              has_other_impls
                              && Codegen_builtins.lookup "" method_name = None
                            then error_no_impl reg e.loc method_name type_name
                            else e)
                    | None -> e)
              | _ -> e
            in
            match first_arg_type_name args with
            | Some type_name -> (
                if is_direct_call_target () then e
                else
                  (* Surgical shadow guard: a top-level [CDFunc] with the
                     same bare name shadows this call only if its
                     first-param type-head matches the call's first-arg
                     type-head. Lets calls on types the shadow doesn't
                     cover (e.g. tuple-typed args when the shadow is
                     [to_string(JsonValue)]) route through the impl
                     registry uniformly. *)
                  let shadowed_here =
                    match ufcs_target with
                    | Some _ -> false
                    | None -> (
                        match
                          Hashtbl.find_opt reg.shadowed_names method_name
                        with
                        | Some heads -> (
                            List.mem type_name heads
                            ||
                            match first_arg_type_head args with
                            | Some head -> List.mem head heads
                            | None -> false)
                        | None -> false)
                  in
                  if shadowed_here then e
                  else
                    match
                      Hashtbl.find_opt reg.impls (method_name, type_name)
                    with
                    | Some mangled ->
                        (* Self-recursion guard: the stdlib pattern
                            [implements Stringable for Int:
                              pure func to_string(val: Int): val.to_string()]
                          delegates to [Core_specialize]'s [blorp_to_string]
                          dispatch and would infinitely recurse if rewritten.
                          But this only applies to types with a specialize
                          fallback — non-primitive impls (JsonValue, user
                          records, tuples) genuinely recurse and need the
                          rewrite to produce a direct self-call.
                          [has_operator_fast_path] identifies the types
                          whose trait methods have hardcoded C dispatches. *)
                        let is_primitive_fallback =
                          match (List.hd args).ty with
                          | t when has_operator_fast_path t -> true
                          | _ -> false
                        in
                        if Some mangled = in_func && is_primitive_fallback then
                          e
                        else
                          let callee' =
                            { callee with desc = CVar (Var.named mangled) }
                          in
                          { e with desc = CCall (CKUnknown, callee', args) }
                    | None ->
                        (* Fire only when [impls_by_method[v.vname]] is
                          non-empty — see the module-level "Diagnostics"
                          section for why. *)
                        let has_other_impls =
                          match
                            Hashtbl.find_opt reg.impls_by_method method_name
                          with
                          | Some (_ :: _) -> true
                          | _ -> false
                        in
                        if
                          has_other_impls
                          && Hashtbl.mem reg.trait_methods method_name
                          && Codegen_builtins.lookup "" method_name = None
                          && not
                               (match args with
                               | first :: _ -> has_operator_fast_path first.ty
                               | [] -> false)
                        then error_no_impl reg e.loc method_name type_name
                        else e)
            | None -> try_static_self_dispatch ())
      | _ -> e)
  | CBin (op, l, r) -> (
      match binop_method op with
      | Some m -> (
          match try_rewrite_operator reg e m [ l; r ] with
          | Some rewritten -> rewritten
          | None -> e)
      | None -> e)
  | CUn (op, x) -> (
      match unop_method op with
      | Some m -> (
          match try_rewrite_operator reg e m [ x ] with
          | Some rewritten -> rewritten
          | None -> e)
      | None -> e)
  | _ -> e

let resolve_func (reg : registry) (f : core_func) : core_func =
  match f.cf_body with
  | None -> f
  | Some body ->
      {
        f with
        cf_body =
          Some
            (resolve_expr reg f.cf_module (Some f.cf_name) StringSet.empty body);
      }

(** Resolve an impl's methods. Each impl method's body is rewritten with
    its own mangled name (e.g. [Trait_method_Type]) as the [in_func]
    self-reference guard, not the method's bare name — otherwise a body
    that delegates via the bare name (the common stdlib shadow pattern)
    would pass the guard and self-recurse. *)
let resolve_impl_method (reg : registry) (trait_name : string)
    (type_name : string) (f : core_func) : core_func =
  match f.cf_body with
  | None -> f
  | Some body ->
      let mangled = Printf.sprintf "%s_%s_%s" trait_name f.cf_name type_name in
      {
        f with
        cf_body =
          Some
            (resolve_expr reg f.cf_module (Some mangled) StringSet.empty body);
      }

let rec resolve_decl (reg : registry) (d : core_decl) : core_decl =
  let desc' =
    match d.cd_desc with
    | CDFunc f -> CDFunc (resolve_func reg f)
    | CDVar v ->
        CDVar
          {
            v with
            cv_init =
              resolve_expr reg v.cv_module None StringSet.empty v.cv_init;
          }
    | CDImpl i -> (
        match Codegen_types.type_key_for_impl i.ci_for_type with
        | Some type_name ->
            CDImpl
              {
                i with
                ci_methods =
                  List.map
                    (resolve_impl_method reg i.ci_trait type_name)
                    i.ci_methods;
              }
        | None ->
            (* Shape has no impl-lookup key — leave methods as-is.
                Matches [collect_registry] which also skips them. *)
            CDImpl i)
    | CDPrivate inner -> CDPrivate (resolve_decl reg inner)
    | other -> other
  in
  { d with cd_desc = desc' }

let resolve_program ?(import_aliases = Hashtbl.create 0)
    ?(module_imports = Hashtbl.create 0) (prog : core_program) : core_program =
  let reg = collect_registry ~import_aliases ~module_imports prog in
  List.map (resolve_decl reg) prog
