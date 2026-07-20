(** Module flattening pass: prefix module-local names with their
    owning module's sanitized name so downstream Core passes see a
    flat namespace with globally unique identifiers.

    Two logically separate pieces live here:

    1. [prefix_module_names] — rewrites a single module's declarations
       so that function, variable, and reference names carry a
       [mod_name__] prefix. Also handles the stdlib HOF
       pure/impure-overload pattern by suffixing the pure variant
       with [__pure] (pre-Phase-2.7 dedup lived here as reactive
       cleanup; Phase 2.7 replaced it with proactive disambiguation).

    2. [build_import_tables_from_bindings] — turns typed import
       bindings into two lookup tables used by [Core_mono] /
       [Core_resolve] for cross-module dispatch: an [import_aliases]
       table for the main program and a per-module [module_imports]
       table for stdlib modules that import each other.

    Phase 5.5 (2026-04-21): extracted from [core_pipeline.ml] so the
    pipeline module becomes the thin orchestrator it should be. Pure
    extraction — no behavior change. *)

let sanitize_module_name = Codegen_names.sanitize_module_name

let should_flatten_type_name module_name type_name =
  (not (Types.is_std_module_name module_name))
  || not (Types.is_global_abi_type_name type_name)

let flattened_type_name_for_module module_name type_name =
  if should_flatten_type_name module_name type_name then
    sanitize_module_name module_name ^ "__" ^ type_name
  else type_name

let rewrite_canonical_type_name ty =
  Types.map_type_expr
    (function
      | Ast.TyNamed (name, args) -> (
          match Types.split_canonical_module_type_name name with
          | Some (module_name, type_name) ->
              Some
                (Ast.TyNamed
                   (flattened_type_name_for_module module_name type_name, args))
          | None -> None)
      | _ -> None)
    ty

(** Rewrite frontend canonical module-owned type identities to the flat Core
    type names used by declarations after [prefix_module_names]. Main-program
    Core is not module-prefixed, so this pass runs over the assembled program
    before registry population/codegen. *)
let rewrite_canonical_module_type_names (prog : Core.core_program) :
    Core.core_program =
  Core.map_types_in_program rewrite_canonical_type_name prog

let exported_type_name (d : Ast.decl) =
  let rec extract d =
    match d.Ast.decl_desc with
    | Ast.DPrivate inner -> extract inner
    | Ast.DRecord r when not r.record_is_builtin -> Some r.record_name
    | Ast.DType t when not t.type_is_builtin -> Some t.type_name
    | Ast.DTypeAlias a -> Some a.alias_name
    | _ -> None
  in
  extract d

let exported_type_targets (loaded : Modules.loaded_module) =
  List.filter_map
    (fun (_export_name, decl) ->
      Option.map
        (fun type_name ->
          (type_name, flattened_type_name_for_module loaded.name type_name))
        (exported_type_name decl))
    loaded.Modules.exports

type imported_type_rewrites = {
  imported_type_names : (string, string) Hashtbl.t;
  imported_type_conflicts : (string, unit) Hashtbl.t;
}

let create_imported_type_rewrites () =
  {
    imported_type_names = Hashtbl.create 16;
    imported_type_conflicts = Hashtbl.create 4;
  }

let add_imported_type_rewrite rewrites local target =
  if not (Hashtbl.mem rewrites.imported_type_conflicts local) then
    match Hashtbl.find_opt rewrites.imported_type_names local with
    | None -> Hashtbl.replace rewrites.imported_type_names local target
    | Some existing when existing = target -> ()
    | Some _ ->
        Hashtbl.remove rewrites.imported_type_names local;
        Hashtbl.replace rewrites.imported_type_conflicts local ()

let find_imported_type_rewrite rewrites name =
  Hashtbl.find_opt rewrites.imported_type_names name

let type_names_in_type ty =
  let rec collect acc = function
    | Ast.TyNamed (name, args) ->
        List.fold_left collect (name :: acc) args
    | Ast.TyArray (element, dims) ->
        List.fold_left collect (collect acc element) dims
    | Ast.TyTuple elements -> List.fold_left collect acc elements
    | Ast.TyFunc fn ->
        collect (List.fold_left collect acc fn.params) fn.return
    | Ast.TyRange inner -> collect acc inner
    | Ast.TyDimOp (_, left, right) -> collect (collect acc left) right
    | Ast.TyVar _ | Ast.TyVarDims _ | Ast.TyBoundVar _ | Ast.TyConstInt _
    | Ast.TySelf | Ast.TyMeta _ ->
        acc
  in
  collect [] ty

(** A selectively imported value can introduce module-owned types through its
    signature even when those types were not imported by name. Record those
    dependencies so Core expression types use the same flattened identity as
    the imported declaration. *)
let add_imported_signature_type_rewrites rewrites targets decl =
  let rec signature_type_names (d : Ast.decl) =
    match d.decl_desc with
    | Ast.DFunc f ->
        let param_names =
          List.concat_map
            (fun (param : Ast.param) ->
              match param.param_type with
              | Some ty -> type_names_in_type ty
              | None -> [])
            f.func_params
        in
        let return_names =
          match f.func_return_type with
          | Some ty -> type_names_in_type ty
          | None -> []
        in
        param_names @ return_names
    | Ast.DPrivate inner -> signature_type_names inner
    | _ -> []
  in
  List.iter
    (fun name ->
      match List.assoc_opt name targets with
      | Some target -> add_imported_type_rewrite rewrites name target
      | None -> ())
    (signature_type_names decl)

(** Build the type identities exposed by one explicitly supplied typed module.
    The semantic worker deliberately has no [Modules] cache, so production
    lowering must derive this information from its request rather than ambient
    process state. *)
let exported_type_targets_for_program module_name (program : Ast.program) =
  List.filter_map
    (fun decl ->
      Option.map
        (fun type_name ->
          (type_name, flattened_type_name_for_module module_name type_name))
        (exported_type_name decl))
    program

let rec decl_source_name (decl : Ast.decl) =
  match decl.decl_desc with
  | Ast.DFunc f -> f.func_name
  | Ast.DVar v -> v.var_name
  | Ast.DRecord r -> Some r.record_name
  | Ast.DType t -> Some t.type_name
  | Ast.DTypeAlias a -> Some a.alias_name
  | Ast.DTrait t -> Some t.trait_name
  | Ast.DPrivate inner -> decl_source_name inner
  | Ast.DImport _ | Ast.DImpl _ -> None

let find_decl_named name program =
  List.find_opt
    (fun decl -> Option.equal String.equal (decl_source_name decl) (Some name))
    program

let add_imported_type_rewrites_from_bindings rewrites
    ~(module_programs : (string * Ast.program) list)
    (bindings : Session.import_binding list) =
  List.iter
    (fun (binding : Session.import_binding) ->
      match
        ( binding.original_name,
          List.assoc_opt binding.module_path module_programs )
      with
      | Some original_name, Some module_program ->
          let targets =
            exported_type_targets_for_program binding.module_path module_program
          in
          (match List.assoc_opt original_name targets with
          | Some target ->
              add_imported_type_rewrite rewrites binding.local_name target
          | None ->
              Option.iter
                (add_imported_signature_type_rewrites rewrites targets)
                (find_decl_named original_name module_program))
      | None, _ | _, None -> ())
    bindings

(** Rewrite selectively imported type names in the main program to the same
    flattened owner names used by module declarations. Bindings for imported
    values also expose the module-owned types in their signatures; inferred
    call-result types otherwise retain a bare name after typed-AST decoding.

    Qualified-only bindings are intentionally ignored here: frontend type
    resolution has already preserved those as canonical module-owned names. *)
let rewrite_main_imported_type_names_from_bindings
    ~(main_import_bindings : Session.import_binding list)
    ~(module_programs : (string * Ast.program) list) (prog : Core.core_program) :
    Core.core_program =
  let imported_types = create_imported_type_rewrites () in
  add_imported_type_rewrites_from_bindings imported_types ~module_programs
    main_import_bindings;
  let rewrite_type ty =
    Types.map_type_expr
      (function
        | Ast.TyNamed (name, args) -> (
            match find_imported_type_rewrite imported_types name with
            | Some target -> Some (Ast.TyNamed (target, args))
            | None -> None)
        | _ -> None)
      ty
  in
  Core.map_types_in_program rewrite_type prog

(** Prefix all function, variable, and module-local type names in a module's Core declarations
    with the sanitized module name, and rewrite intra-module references
    to match. After this, the IR has a flat namespace with globally
    unique names — no downstream pass needs module awareness.

    Skips for value-level names: builtin and foreign functions (anything
    other than [CFUser]), and UFCS-mangled names (already encode module).
    Std primitive/prelude ABI type names stay stable; all other std-local type
    declarations are flattened like user module types to avoid same-name layout
    collisions. *)
let prefix_module_names ?(import_bindings = []) ?(module_programs = [])
    (mod_name : string) (decls : Core.core_program) : Core.core_program =
  let prefix = sanitize_module_name mod_name in
  let defined = Hashtbl.create 32 in
  let local_type_names = Hashtbl.create 16 in
  let imported_types = create_imported_type_rewrites () in
  add_imported_type_rewrites_from_bindings imported_types ~module_programs
    import_bindings;
  let should_skip name =
    match Codegen_names.parse_ufcs_name name with
    | Some _ -> true
    | None -> false
  in
  let prefixed_type_name name = prefix ^ "__" ^ name in
  let rewrite_declared_type_name name =
    if Hashtbl.mem local_type_names name then prefixed_type_name name else name
  in
  let rewrite_type ty =
    Types.map_type_expr
      (function
        | Ast.TyNamed (name, args) -> (
            match Types.split_canonical_module_type_name name with
            | Some (module_name, type_name) ->
                Some
                  (Ast.TyNamed
                     (flattened_type_name_for_module module_name type_name, args))
            | None when Hashtbl.mem local_type_names name ->
                Some (Ast.TyNamed (prefixed_type_name name, args))
            | None -> (
                match find_imported_type_rewrite imported_types name with
                | Some target -> Some (Ast.TyNamed (target, args))
                | None -> None))
        | _ -> None)
      ty
  in
  let rec collect_local_type_names d =
    match d.Core.cd_desc with
    | Core.CDRecord r
      when (not r.Ast.record_is_builtin)
           && should_flatten_type_name mod_name r.Ast.record_name ->
        Hashtbl.replace local_type_names r.Ast.record_name ()
    | Core.CDType t when should_flatten_type_name mod_name t.Ast.type_name ->
        Hashtbl.replace local_type_names t.Ast.type_name ()
    | Core.CDTypeAlias a when should_flatten_type_name mod_name a.Ast.alias_name
      ->
        Hashtbl.replace local_type_names a.Ast.alias_name ()
    | Core.CDPrivate inner -> collect_local_type_names inner
    | _ -> ()
  in
  List.iter collect_local_type_names decls;
  let collect_imported_type_names (imp : Ast.import_decl) =
    match Modules.find_cached imp.Ast.import_module with
    | None -> ()
    | Some loaded -> (
        let targets = exported_type_targets loaded in
        match imp.import_symbols with
        | Some symbols ->
            List.iter
              (fun (sym : Ast.import_symbol) ->
                match List.assoc_opt sym.sym_name targets with
                | Some target ->
                    let local =
                      Option.value sym.sym_alias ~default:sym.sym_name
                    in
                    add_imported_type_rewrite imported_types local target
                | None -> ())
              symbols
        | None ->
            (* Typecheck currently resolves [Alias.Type] annotations to the
                bare [Type] name. Preserve codegen correctness for the common
                unambiguous case by mapping each uniquely exported type name
                from qualified imports back to its flattened module owner. *)
            List.iter
              (fun (type_name, target) ->
                add_imported_type_rewrite imported_types type_name target)
              targets)
  in
  let rec collect_imports d =
    match d.Core.cd_desc with
    | Core.CDImport imp -> collect_imported_type_names imp
    | Core.CDPrivate inner -> collect_imports inner
    | _ -> ()
  in
  List.iter collect_imports decls;
  (* Pre-scan: find source names that have BOTH pure and impure overloads
     in this module (the stdlib HOF pattern from std/list.brp et al). The
     pure variant of such a pair gets a [__pure] suffix on its prefixed
     name so both survive module flattening with distinct identities.

     Call-site resolution: [Core_resolve.try_resolve_module_func] looks
     up the unsuffixed name first, falling back to [__pure] when that
     misses. [Core_mono] has the same fallback for generic calls. So
     when a module exports only the pure variant with a body (e.g.
     [std/option.brp]'s forward-decl impure + bodied pure pattern),
     callers find it via the fallback. When both variants carry bodies
     ([std/list.brp] pattern), the impure wins the primary name and
     the pure variant becomes unreferenced — Mono then drops it
     (generic) or the emitter skips it (non-generic with type params).

     Phase 2.7 replaces the previous reactive dedup hack that dropped
     one variant or renamed it after the fact. The fully ideal path
     (tasks 48/49 — tiebreak overload resolution by callback purity and
     rewrite call-site names to hit the pure variant) is deferred
     because no runtime test requires it today; the architectural win
     is enabling future purity-driven stdlib optimizations. *)
  let purity_overloads = Hashtbl.create 16 in
  let rec scan_purity d =
    match d.Core.cd_desc with
    | Core.CDFunc f
      when f.cf_body <> None
           && (not (Core.is_builtin_kind f.cf_kind))
           && not (should_skip f.cf_name) ->
        let has_pure, has_impure =
          match Hashtbl.find_opt purity_overloads f.cf_name with
          | Some p -> p
          | None -> (false, false)
        in
        let updated =
          if f.cf_is_pure then (true, has_impure) else (has_pure, true)
        in
        Hashtbl.replace purity_overloads f.cf_name updated
    | Core.CDPrivate inner -> scan_purity inner
    | _ -> ()
  in
  List.iter scan_purity decls;
  (* [is_paired name] — source name has both pure and impure variants. *)
  let is_paired name =
    match Hashtbl.find_opt purity_overloads name with
    | Some (true, true) -> true
    | _ -> false
  in
  (* Disambiguated source name for a paired pure variant gets a [__pure]
     suffix; others use the raw source name. *)
  let disambiguate_source (f : Core.core_func) : string =
    if is_paired f.cf_name && f.cf_is_pure then f.cf_name ^ "__pure"
    else f.cf_name
  in
  let rec collect_names d =
    match d.Core.cd_desc with
    | Core.CDFunc f
      when f.cf_body <> None
           && (not (Core.is_builtin_kind f.cf_kind))
           && not (should_skip f.cf_name) ->
        let src = disambiguate_source f in
        Hashtbl.replace defined src (prefix ^ "__" ^ src)
    | Core.CDVar v when not (should_skip v.cv_name.vname) ->
        Hashtbl.replace defined v.cv_name.vname (prefix ^ "__" ^ v.cv_name.vname)
    | Core.CDImpl _ -> () (* impl methods get mangled by emit_impl *)
    | Core.CDPrivate inner -> collect_names inner
    | _ -> ()
  in
  List.iter collect_names decls;
  let rewrite_name name =
    match Hashtbl.find_opt defined name with
    | Some prefixed -> prefixed
    | None -> name
  in
  let rewrite_var (v : Core.var) = { v with vname = rewrite_name v.vname } in
  let rewrite_param (p : Core.core_param) =
    { p with cp_ty = rewrite_type p.cp_ty }
  in
  let rewrite_closure_abi (abi : Core.closure_abi) =
    {
      Core.ca_params =
        List.map (fun (v, ty) -> (v, rewrite_type ty)) abi.Core.ca_params;
      ca_captures =
        List.map
          (fun (name, ty) -> (name, rewrite_type ty))
          abi.Core.ca_captures;
      ca_moved_captures = abi.Core.ca_moved_captures;
      ca_task_abi = abi.Core.ca_task_abi;
    }
  in
  let rewrite_func_kind = function
    | Core.CFClosureBody abi -> Core.CFClosureBody (rewrite_closure_abi abi)
    | kind -> kind
  in
  let rewrite_expr_type_desc desc =
    match desc with
    | Core.CLambda lam ->
        Core.CLambda
          {
            lam with
            lam_params =
              List.map (fun (v, ty) -> (v, rewrite_type ty)) lam.lam_params;
            lam_return_ty = rewrite_type lam.lam_return_ty;
          }
    | Core.CClosureCreate cc ->
        Core.CClosureCreate
          {
            cc with
            cc_captures =
              List.map
                (fun (name, ty) -> (name, rewrite_type ty))
                cc.cc_captures;
          }
    | Core.CLet (b, body) ->
        Core.CLet ({ b with bind_ty = rewrite_type b.bind_ty }, body)
    | Core.CBorrowLet (b, body) ->
        Core.CBorrowLet ({ b with borrow_ty = rewrite_type b.borrow_ty }, body)
    | Core.CFor (binder, iter, body) ->
        Core.CFor
          ({ binder with loop_ty = rewrite_type binder.loop_ty }, iter, body)
    | Core.CDup (v, ty, body) -> Core.CDup (v, rewrite_type ty, body)
    | Core.CDrop (v, ty, body) -> Core.CDrop (v, rewrite_type ty, body)
    | Core.CConcurrent cb ->
        Core.CConcurrent
          {
            cb with
            conc_bindings =
              List.map
                (fun (b : Core.conc_binding) ->
                  { b with cb_ty = rewrite_type b.cb_ty })
                cb.conc_bindings;
          }
    | Core.CCast (x, ty) -> Core.CCast (x, rewrite_type ty)
    | Core.CUnbox (x, ty) -> Core.CUnbox (x, rewrite_type ty)
    | Core.CBox (x, ty) -> Core.CBox (x, rewrite_type ty)
    | other -> other
  in
  let rewrite_expr_node e desc =
    {
      e with
      Core.ty = rewrite_type e.Core.ty;
      desc = rewrite_expr_type_desc desc;
    }
  in
  let module SS = Set.Make (String) in
  let rec rewrite_expr_scoped bound e =
    match e.Core.desc with
    | Core.CVar v ->
        let v' = if SS.mem v.vname bound then v else rewrite_var v in
        rewrite_expr_node e (Core.CVar v')
    | Core.CLet (b, body) ->
        let rhs' = rewrite_expr_scoped bound b.bind_rhs in
        let bound' = SS.add b.bind_var.vname bound in
        let body' = rewrite_expr_scoped bound' body in
        rewrite_expr_node e (Core.CLet ({ b with bind_rhs = rhs' }, body'))
    | Core.CBorrowLet (b, body) ->
        let rhs' = rewrite_expr_scoped bound b.borrow_rhs in
        let bound' = SS.add b.borrow_var.vname bound in
        let body' = rewrite_expr_scoped bound' body in
        rewrite_expr_node e
          (Core.CBorrowLet ({ b with borrow_rhs = rhs' }, body'))
    | Core.CLambda lam ->
        let inner =
          List.fold_left
            (fun s (v, _) -> SS.add v.Core.vname s)
            bound lam.lam_params
        in
        rewrite_expr_node e
          (Core.CLambda
             { lam with lam_body = rewrite_expr_scoped inner lam.lam_body })
    | Core.CFor (binder, iter, body) ->
        let iter' = rewrite_expr_scoped bound iter in
        let bound' = SS.add binder.loop_var.vname bound in
        rewrite_expr_node e
          (Core.CFor (binder, iter', rewrite_expr_scoped bound' body))
    | Core.CResourceScope scope ->
        let acquire' = rewrite_expr_scoped bound scope.rs_acquire in
        let bound' = SS.add scope.rs_var.vname bound in
        let body' = rewrite_expr_scoped bound' scope.rs_body in
        let cleanup' = rewrite_expr_scoped bound' scope.rs_cleanup in
        rewrite_expr_node e
          (Core.CResourceScope
             {
               scope with
               rs_ty = rewrite_type scope.rs_ty;
               rs_acquire = acquire';
               rs_body = body';
               rs_cleanup = cleanup';
             })
    | Core.CMatchArms (scrut, arms) ->
        let scrut' = rewrite_expr_scoped bound scrut in
        let arms' =
          List.map
            (fun (pat, body) ->
              let pvars = Core.pat_vars pat in
              let inner = List.fold_left (fun s n -> SS.add n s) bound pvars in
              (pat, rewrite_expr_scoped inner body))
            arms
        in
        rewrite_expr_node e (Core.CMatchArms (scrut', arms'))
    | Core.CAssign (v, rhs) ->
        let v' = if SS.mem v.Core.vname bound then v else rewrite_var v in
        rewrite_expr_node e (Core.CAssign (v', rewrite_expr_scoped bound rhs))
    | _ ->
        let e' = Core.map_children (rewrite_expr_scoped bound) e in
        rewrite_expr_node e' e'.Core.desc
  in
  let rewrite_func (f : Core.core_func) =
    let param_names =
      List.map (fun (p : Core.core_param) -> p.cp_name.vname) f.cf_params
    in
    let bound = List.fold_left (fun s n -> SS.add n s) SS.empty param_names in
    (* Paired pure variant: its source name was augmented with [__pure]
       by [disambiguate_source] before we populated [defined]. Look up
       the prefixed form via that disambiguated name. *)
    let src_name = disambiguate_source f in
    let new_name = rewrite_name src_name in
    {
      f with
      cf_name = new_name;
      cf_module = Some mod_name;
      cf_params = List.map rewrite_param f.cf_params;
      cf_return_ty = rewrite_type f.cf_return_ty;
      cf_kind = rewrite_func_kind f.cf_kind;
      cf_body = Option.map (rewrite_expr_scoped bound) f.cf_body;
    }
  in
  (* Impl methods must NOT have [cf_name] rewritten — the method's bare
     name is what [emit_impl] mangles into [Trait_method_Type], and what
     [core_trait_resolve]'s registry keys by. A same-named top-level
     function in the same module (e.g. [std/bytes.brp]'s top-level
     [length] shadowing the [HasLength for Bytes] method) would
     otherwise clobber the impl method's name and cause
     [emit_impl]'s mangling to disagree with the call-site's. *)
  let rewrite_impl_method (f : Core.core_func) =
    let param_names =
      List.map (fun (p : Core.core_param) -> p.cp_name.vname) f.cf_params
    in
    let bound = List.fold_left (fun s n -> SS.add n s) SS.empty param_names in
    {
      f with
      cf_module = Some mod_name;
      cf_params = List.map rewrite_param f.cf_params;
      cf_return_ty = rewrite_type f.cf_return_ty;
      cf_kind = rewrite_func_kind f.cf_kind;
      cf_body = Option.map (rewrite_expr_scoped bound) f.cf_body;
    }
  in
  let rewrite_field_decl (fd : Ast.field_decl) =
    { fd with field_type = rewrite_type fd.field_type }
  in
  let rewrite_variant (v : Ast.variant) =
    { v with variant_fields = List.map rewrite_type v.variant_fields }
  in
  let rewrite_record_decl (r : Ast.record_decl) =
    {
      r with
      record_name = rewrite_declared_type_name r.record_name;
      record_fields = List.map rewrite_field_decl r.record_fields;
    }
  in
  let rewrite_type_decl (t : Ast.type_decl) =
    {
      t with
      type_name = rewrite_declared_type_name t.type_name;
      type_variants = List.map rewrite_variant t.type_variants;
    }
  in
  let rewrite_type_alias (a : Ast.type_alias_decl) =
    {
      a with
      alias_name = rewrite_declared_type_name a.alias_name;
      alias_target = rewrite_type a.alias_target;
    }
  in
  let rewrite_trait_method (m : Core.core_trait_method) =
    {
      m with
      ctm_params = List.map rewrite_param m.ctm_params;
      ctm_return_ty = Option.map rewrite_type m.ctm_return_ty;
    }
  in
  let rec rewrite_decl d =
    let desc' =
      match d.Core.cd_desc with
      | Core.CDFunc f -> Core.CDFunc (rewrite_func f)
      | Core.CDVar v ->
          Core.CDVar
            {
              v with
              cv_name = rewrite_var v.cv_name;
              cv_module = Some mod_name;
              cv_ty = rewrite_type v.cv_ty;
              cv_init = rewrite_expr_scoped SS.empty v.cv_init;
            }
      | Core.CDImpl i ->
          Core.CDImpl
            {
              i with
              ci_for_type = rewrite_type i.ci_for_type;
              ci_methods = List.map rewrite_impl_method i.ci_methods;
            }
      | Core.CDTrait t ->
          Core.CDTrait
            { t with ct_methods = List.map rewrite_trait_method t.ct_methods }
      | Core.CDRecord r -> Core.CDRecord (rewrite_record_decl r)
      | Core.CDType t -> Core.CDType (rewrite_type_decl t)
      | Core.CDTypeAlias a -> Core.CDTypeAlias (rewrite_type_alias a)
      | Core.CDPrivate inner -> Core.CDPrivate (rewrite_decl inner)
      | other -> other
    in
    { d with cd_desc = desc' }
  in
  let rewritten = List.map rewrite_decl decls in
  (* Dedup: transitive module imports can re-export the same function,
     producing duplicates after prefixing. Phase 2.7: names are now
     pre-disambiguated by [disambiguate_source] — pure/impure overloads
     get distinct prefixed names proactively — so true duplicates can be
     dropped strictly.

     Body-preferring: when the same prefixed name has both a forward-
     decl (body=None) and a bodied variant, keep the bodied one. This
     matters for the [std/option.brp] pattern where the impure [func
     map] is a forward declaration and the pure [pure func map] carries
     the implementation; without body-preference the forward-decl wins
     by source order and the implementation disappears from the linker's
     symbol table. *)
  let name_has_body = Hashtbl.create 32 in
  List.iter
    (fun d ->
      match d.Core.cd_desc with
      | Core.CDFunc f when f.cf_body <> None ->
          Hashtbl.replace name_has_body f.cf_name ()
      | _ -> ())
    rewritten;
  let seen = Hashtbl.create 32 in
  List.filter_map
    (fun d ->
      match d.Core.cd_desc with
      | Core.CDFunc f ->
          if Hashtbl.mem seen f.cf_name then None
          else if f.cf_body = None && Hashtbl.mem name_has_body f.cf_name then begin
            (* A bodied variant exists later in the list; drop this
               forward-decl so the bodied one is kept when we reach it. *)
            None
          end
          else (
            Hashtbl.replace seen f.cf_name ();
            Some d)
      | _ -> Some d)
    rewritten

(** Walk a Core program and populate the shared type registry with
    every type alias, enum type, and value-record name the program
    declares. [Core_mono] reads these from [reg] to expand aliases
    eagerly (otherwise structural unification misses the expansion);
    the Blorp Perceus pass and C emitter use the same
    registrations so ownership classification and C layout agree about
    value records, enums, aliases, and managed destructor policies.

    Previously duplicated inline in both [Core_pipeline.compile_typed] and
    [Core_pipeline.compile_typed_with_modules]; hoisted here to make the
    type-registry population step a single named operation. *)
let register_types (reg : Codegen_types.registry) (prog : Core.core_program) :
    unit =
  let rec seed d =
    match d.Core.cd_desc with
    | Core.CDTypeAlias a ->
        Hashtbl.replace reg.type_aliases a.alias_name
          (Ast.type_param_names a.alias_type_params, a.alias_target)
    | Core.CDType t when t.type_is_enum ->
        Codegen_types.register_enum_type reg t.type_name t.type_variants
    | Core.CDType t when not t.type_is_builtin ->
        Codegen_types.register_union_variants reg t.type_name t.type_variants;
        Codegen_types.register_union_type reg t.type_name
          ~payload_storage:(Codegen_types.source_union_payload_storage t)
          ~destructor:
            (Codegen_types.GeneratedDestructor (t.type_name ^ "_destroy"))
    | Core.CDRecord r when r.record_is_builtin -> ()
    | Core.CDRecord r when r.record_is_value ->
        Hashtbl.replace reg.value_records r.record_name ()
    | Core.CDRecord r ->
        Codegen_types.register_heap_record_type reg r.record_name
          ~destructor:
            (Codegen_types.GeneratedDestructor (r.record_name ^ "_destroy"))
    | Core.CDPrivate inner -> seed inner
    | _ -> ()
  in
  let rec refine d =
    match d.Core.cd_desc with
    | Core.CDType t when (not t.type_is_enum) && not t.type_is_builtin ->
        Codegen_types.register_union_type reg t.type_name
          ~payload_storage:(Codegen_types.source_union_payload_storage t)
          ~destructor:(Core_layout_type.union_destructor_policy ~reg t)
    | Core.CDRecord r when (not r.record_is_value) && not r.record_is_builtin ->
        Codegen_types.register_heap_record_type reg r.record_name
          ~destructor:(Core_layout_type.record_destructor_policy ~reg r)
    | Core.CDPrivate inner -> refine inner
    | _ -> ()
  in
  List.iter seed prog;
  List.iter refine prog

let import_table_of_bindings (bindings : Session.import_binding list) =
  let table = Hashtbl.create 16 in
  List.iter
    (fun (binding : Session.import_binding) ->
      let original_name = Option.value binding.original_name ~default:"" in
      Hashtbl.replace table binding.local_name
        (binding.module_path, original_name))
    bindings;
  table

let build_import_tables_from_bindings
    ~(main_import_bindings : Session.import_binding list)
    (module_bindings : (string * Session.import_binding list) list) :
    (string, string * string) Hashtbl.t
    * (string, (string, string * string) Hashtbl.t) Hashtbl.t =
  let module_imports = Hashtbl.create 32 in
  List.iter
    (fun (module_name, bindings) ->
      let table = import_table_of_bindings bindings in
      if Hashtbl.length table > 0 then
        Hashtbl.replace module_imports module_name table)
    module_bindings;
  (import_table_of_bindings main_import_bindings, module_imports)
