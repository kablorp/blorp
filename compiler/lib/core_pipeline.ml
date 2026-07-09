(** Core IR compilation pipeline.

    Chains the Core passes in order:
    1. [Core_lower] + [Core_ffi_boundary] — typed AST → Core IR, with checked
       FFI argument-boundary policies attached after type registration
    2. [Core_debug] — erase or retain explicit debug blocks
    3. [Core_desugar] + [Core_ssa] — eliminate Core sugar and mutable locals
    4. [Core_mono] — monomorphize generic functions
    5. [Core_synth] — synthesize concrete builtin IR bodies post-mono
    6. [Core_match] — compile CMatchArms → CMatch decision trees
    7. [Core_trait_resolve] — rewrite trait methods/operators to impl calls
    8. [Core_resolve] — tag CCall by callee kind
    9. [Core_std_inline] — expand compiler-owned std wrappers at call sites
    10. [Core_tailrec] — make tail-recursive self-loops explicit
    11. [Core_string_pipeline] + [Core_collection_pipeline] +
       [Core_parallel_tensor_pipeline] + [Core_tensor_fusion] +
       [Core_tuple_sroa] — fuse compatible string/list/scoped tensor pipelines
       and tensor update expressions; scalar-replace non-escaping local tuples
       and narrow tuple-return call sites
    12. [Core_specialize] + function-ref adaptation — type-dispatch builtins
       to CCast / concrete names; make eta adapters visible to Perceus
    13. [Core_dce] — prune unreachable concrete functions, impl methods,
       non-runtime generic function/impl templates, and source-only type
       declarations
    14. [Core_consume_specialize] — clone safe self-replacement callees with
       explicit consumed parameters
    15. [Core_perceus] — insert CDup/CDrop for reference counting
    16. backend handoff — default compilation gives post-Perceus Core to Blorp
    17. Blorp-owned final tail — normal reuse, closure conversion, resource
       cleanup lowering, fairness checkpoints, codegen preparation, prepared
       reuse, and C artifact emission

    OCaml program-bearing callbacks stop at the post-Perceus handoff. CLI
    late-stage dumps/stops use Blorp Core JSON observation instead. Timing-only
    observation uses lightweight stage events. Normal C output always comes
    from the Blorp post-Perceus handoff.

    This module is the single entry point for routing a typed program
    through the Core path instead of the legacy [Codegen.generate]. *)

(* Module flattening (prefix_module_names, import-table assembly) moved
   to [Core_flatten] in Phase 5.5. Call sites below go through the
   extracted module. *)

exception Stopped_after of Core_stage.t
(** Exception raised from within an [on_stage_callback] to request that
    the pipeline stop after the named stage. Caught at the [Pipeline]
    boundary and converted to [Ok (Stopped_at stage)]. Lives here,
    alongside the callback type, rather than in [Core_stage] — the
    stage enum is pure data, this exception is pipeline control flow. *)

type on_stage_callback = Core_stage.t -> Core.core_program -> unit
(** [on_stage_callback] fires once after every OCaml-owned Core pipeline stage,
    with the stage marker and the current [core_program]. The default is a
    no-op.

    Callers use this for [--dump-core-after=<stage>] (dumps the program when
    the stage matches) and [--stop-after=<stage>] (raises
    [Stopped_after] from the callback when the stage matches).

    Raising [Stopped_after] from the callback short-circuits the rest of
    the pipeline — later stages and emission are skipped. The enclosing
    caller in [Pipeline] / CLI layer catches the exception. *)

let no_op_on_stage : on_stage_callback = fun _ _ -> ()

type on_stage_event = Core_stage.t -> unit
(** [on_stage_event] fires once per observed Core stage without a program
    payload. It is for consumers such as timing/profiling that do not need to
    force a Core snapshot. In particular, event-only observation should not
    request Core JSON snapshots from the Blorp-owned backend tail when callers
    only need timing/order. *)

let no_op_on_stage_event : on_stage_event = fun _ -> ()

type on_stage_json_callback = Core_stage.t -> string -> unit
(** [on_stage_json_callback] fires for Blorp-owned stages whose authoritative
    state is only available as bridge JSON. This lets CLI dump/stop observe
    late backend stages without decoding the JSON back into duplicate OCaml Core
    values. *)

let no_op_on_stage_json : on_stage_json_callback = fun _ _ -> ()

(** Stages that transform Core after the initial lowering snapshot. [Lower]
    and [Final] are observations, not transformations, so they are kept out
    of this list and added explicitly in [observed_stage_order]. *)
let transform_stage_order =
  [
    Core_stage.Debug;
    Core_stage.Desugar;
    Core_stage.Mono;
    Core_stage.Synth;
    Core_stage.Match;
    Core_stage.TraitResolve;
    Core_stage.Resolve;
    Core_stage.StdInline;
    Core_stage.Tailrec;
    Core_stage.Fusion;
    Core_stage.Specialize;
    Core_stage.Dce;
    Core_stage.ConsumeSpecialize;
    Core_stage.Perceus;
    Core_stage.Reuse;
    Core_stage.Closure;
  ]

(** The exact order in which [on_stage_callback] fires. This is the
    executable pipeline contract used by tests, docs, dumps, profiling, and
    [--stop-after]. *)
let observed_stage_order =
  (Core_stage.Lower :: transform_stage_order) @ [ Core_stage.Final ]

let stage_observed_via_blorp_tail_json = function
  | Core_stage.Reuse | Core_stage.Closure | Core_stage.Final -> true
  | Core_stage.Lower | Core_stage.Debug | Core_stage.Desugar | Core_stage.Mono
  | Core_stage.Synth | Core_stage.Match | Core_stage.TraitResolve
  | Core_stage.Resolve | Core_stage.StdInline | Core_stage.Tailrec
  | Core_stage.Fusion | Core_stage.Specialize | Core_stage.Dce
  | Core_stage.ConsumeSpecialize | Core_stage.Perceus ->
      false

let pre_backend_program_stage_order =
  List.filter
    (fun stage -> not (stage_observed_via_blorp_tail_json stage))
    observed_stage_order

(** Program-free stage events do not materialize Blorp-owned backend-tail
    snapshots. Reuse and closure are represented by the single [Final] event
    unless a caller explicitly requests their Core JSON snapshots. *)
let program_free_stage_event_order =
  pre_backend_program_stage_order @ [ Core_stage.Final ]

let blorp_tail_stage_name = function
  | (Core_stage.Reuse | Core_stage.Closure | Core_stage.Final) as stage ->
      Some (Core_stage.to_string stage)
  | Core_stage.Lower | Core_stage.Debug | Core_stage.Desugar | Core_stage.Mono
  | Core_stage.Synth | Core_stage.Match | Core_stage.TraitResolve
  | Core_stage.Resolve | Core_stage.StdInline | Core_stage.Tailrec
  | Core_stage.Fusion | Core_stage.Specialize | Core_stage.Dce
  | Core_stage.ConsumeSpecialize | Core_stage.Perceus ->
      None

let core_stage_list_contains target =
  List.exists (fun stage -> stage = target)

(** Critical safety checks that should never be allowed to reach emission,
    even when development invariant checking is disabled. Keep this list
    deliberately small: broad invariant coverage still belongs behind
    [--check-invariants]. *)
let critical_invariant_violations stage prog =
  match stage with
  | Core_stage.Final -> Core_invariants.run_for_stage stage prog
  | _ -> []

let invariant_violations ~check_invariants stage prog =
  if check_invariants then Core_invariants.run_for_stage stage prog
  else critical_invariant_violations stage prog

let fire_stage ~(check_invariants : bool) ~(user : on_stage_callback)
    (stage : Core_stage.t) (prog : Core.core_program) : unit =
  match invariant_violations ~check_invariants stage prog with
  | [] -> user stage prog
  | v :: _ -> raise (Core_error.Core_error v)

(** Compose the user's [on_stage] with invariant checking. Invariant checks
    run {b before} the user callback so violations surface first — otherwise
    [--stop-after=STAGE] (raised from the user callback) would mask any
    post-stage invariant failure. For dump/stop purposes the program is
    identical before and after the check — the check is a pure fold.

    If invariants fire, the user callback never runs. Development checks run
    only when [check_invariants] is true. Default emission hands off before the
    final tail; the Blorp backend boundary rejects unsupported or unresolved
    shapes before producing C. *)
let make_stage_hook ~(check_invariants : bool) ~(user : on_stage_callback) :
    on_stage_callback =
 fun stage prog -> fire_stage ~check_invariants ~user stage prog

let post_perceus_program_json ~reg program =
  match Core_emit_blorp_c.program_json ~reg program with
  | Ok json -> json
  | Error error -> failwith (Core_emit_blorp_c.unsupported_to_string error)

let observe_blorp_tail_json ~reg ~(on_stage_event : on_stage_event)
    ~(on_stage_json : on_stage_json_callback) ~(stages : Core_stage.t list)
    (post_perceus : Core.core_program) =
  match stages with
  | [] -> ()
  | _ :: _ ->
      let core_json = post_perceus_program_json ~reg post_perceus in
      List.iter
        (fun stage ->
          match blorp_tail_stage_name stage with
          | Some stage_name ->
              let transformed =
                Compiler_blorp_bridge.run_core_pipeline_core_json_exn
                  ~stage:stage_name core_json
                |> Lsp_json.to_string
              in
              on_stage_event stage;
              on_stage_json stage transformed
          | None -> ())
        stages

type backend_core_input = {
  blorp_tail_input : Core.core_program;
      (** Post-Perceus Core handed to Blorp for reuse/closure/resource/fairness/
          prepare/prepared-reuse/emission on the default path. *)
}

(** Run C emission through the single Blorp backend path. Normal compilation
    hands off before the final tail so Blorp owns reuse/closure/resource/
    fairness/prepare. Late-stage CLI observation uses [on_stage_json] over the
    Blorp tail. *)
let emit_via_c_backend ~(embed_runtime : bool) ~(profile : bool)
    ~(reg : Codegen_types.registry) ~(on_stage_event : on_stage_event)
    ~(on_stage_json : on_stage_json_callback)
    ~(tail_observation_stages : Core_stage.t list)
    (backend_input : backend_core_input) : string =
  observe_blorp_tail_json ~reg ~on_stage_event ~on_stage_json
    ~stages:tail_observation_stages backend_input.blorp_tail_input;
  let cfg =
    Core_emit_blorp_c.config_with_embed ~embed_runtime ~profile ~reg ()
  in
  let result =
    Core_emit_blorp_c.try_emit_post_closure_program_string cfg
      backend_input.blorp_tail_input
  in
  if
    not (core_stage_list_contains Core_stage.Final tail_observation_stages)
  then on_stage_event Core_stage.Final;
  match result with Ok c_code -> c_code | Error reason -> failwith reason

(** Run the shared Core-to-Core pass chain starting from an already-lowered
    [core_program]. [compile] and [compile_with_modules] differ in how they
    assemble that initial program (single file vs. loaded modules), but the
    pass ordering after lowering is identical. Keeping the sequence in one
    place prevents stage drift between the two entry points. *)
let run_core_passes ?(import_aliases = Hashtbl.create 0)
    ?(module_imports = Hashtbl.create 0) ~(on_stage : on_stage_callback)
    ?(on_stage_event = no_op_on_stage_event) ~(reg : Codegen_types.registry)
    ?(debug = false) (prog : Core.core_program) : backend_core_input =
  let observe stage prog =
    on_stage_event stage;
    on_stage stage prog;
    prog
  in
  let run_stage stage pass prog = pass prog |> observe stage in
  let post_perceus =
    prog |> observe Core_stage.Lower
    |> run_stage Core_stage.Debug (Core_debug.lower_program ~enabled:debug)
    |> run_stage Core_stage.Desugar (fun p ->
        p |> Core_desugar.desugar_program |> Core_ssa.desugar_mut_program)
    |> run_stage Core_stage.Mono (fun p ->
        p
        |> Core_mono.monomorphize_program ~reg ~import_aliases ~module_imports
        |> Core_list_layout.annotate_program ~reg)
    |> run_stage Core_stage.Synth (Core_synth.synthesize_program ~reg)
    |> run_stage Core_stage.Match Core_match.compile_program
    |> run_stage Core_stage.TraitResolve
         (Core_trait_resolve.resolve_program ~import_aliases ~module_imports)
    |> run_stage Core_stage.Resolve
         (Core_resolve.resolve_program ~import_aliases ~module_imports)
    |> run_stage Core_stage.StdInline Core_std_inline.rewrite_program
    |> run_stage Core_stage.Tailrec (Core_tailrec.lower_program ~reg)
    |> run_stage Core_stage.Fusion (fun p ->
        p
        |> Core_string_pipeline.fuse_program ~reg
        |> Core_collection_pipeline.fuse_program ~reg
        |> Core_parallel_tensor_pipeline.fuse_program ~reg
        |> Core_tensor_fusion.fuse_program ~reg
        |> Core_tuple_sroa.rewrite_program ~reg)
    |> run_stage Core_stage.Specialize (fun p ->
        p
        |> Core_specialize.specialize_program ~reg
        |> Core_closure.adapt_function_refs_program)
    |> run_stage Core_stage.Dce (Core_dce.prune_unreachable_declarations ~reg)
    |> run_stage Core_stage.ConsumeSpecialize
         (Core_consume_specialize.rewrite_program ~reg)
    |> run_stage Core_stage.Perceus Core_perceus.insert_drops_program
  in
  { blorp_tail_input = post_perceus }

let compile_typed ?(embed_runtime = false) ?(profile = false) ?(debug = false)
    ?on_stage ?(on_stage_event = no_op_on_stage_event)
    ?(on_stage_json = no_op_on_stage_json) ?(tail_observation_stages = [])
    ?(check_invariants = false) (typed_program : Typed_ast.program) : string =
  let user_on_stage = Option.value ~default:no_op_on_stage on_stage in
  let on_stage = make_stage_hook ~check_invariants ~user:user_on_stage in
  Session.reset_core_counters (Session.current ());
  let core_prog = Core_lower.lower_typed_program typed_program in
  (* Share one registry across mono and emit so type aliases registered at
     either end are visible to both. See [compile_with_modules] for the
     rationale. *)
  let reg = Codegen_types.create_registry () in
  let core_prog = Core_flatten.rewrite_canonical_module_type_names core_prog in
  Core_flatten.register_types reg core_prog;
  let core_prog = Core_ffi_boundary.annotate_program ~reg core_prog in
  let core_prog = Core_list_layout.annotate_program ~reg core_prog in
  let backend_input =
    run_core_passes ~on_stage ~on_stage_event ~reg ~debug core_prog
  in
  emit_via_c_backend ~embed_runtime ~profile ~reg
    ~on_stage_event ~on_stage_json ~tail_observation_stages backend_input

(** Compile a typed AST program with module support.

    Collects all loaded modules (via [Modules.get_all_modules]),
    lowers them alongside the main program, and runs the full
    Core pipeline. Each module's declarations are prefixed with the
    sanitized module name before flattening.

    Returns [(c_code, link_flags, include_dirs)]. *)
let compile_typed_with_modules ?(main_import_bindings = [])
    ?(embed_runtime = true) ?(profile = false) ?(debug = false) ?on_stage
    ?(on_stage_event = no_op_on_stage_event)
    ?(on_stage_json = no_op_on_stage_json) ?(tail_observation_stages = [])
    ?(check_invariants = false) (typed_main : Typed_ast.program) :
    string * string list * string list =
  let user_on_stage = Option.value ~default:no_op_on_stage on_stage in
  let on_stage = make_stage_hook ~check_invariants ~user:user_on_stage in
  let program = Typed_ast.program_ast typed_main in
  Session.reset_core_counters (Session.current ());
  let modules = Modules.get_all_modules () in
  let typed_module_decls (m : Modules.loaded_module) =
    match m.typed_decls with
    | Some td -> td
    | None ->
        Core_error.errorf (Core_error.Stage Core_stage.Lower) Ast.dummy_loc
          ~hint:
            "Pipeline.ensure_modules_typed must type-check every loaded module \
             before Core lowering. If this came from a direct Core_pipeline \
             call, use Pipeline.compile/typecheck_only or populate typed_decls \
             explicitly."
          "module %s reached Core lowering without typed declarations" m.name
  in
  let module_core =
    List.concat_map
      (fun (m : Modules.loaded_module) ->
        let typed_program = typed_module_decls m in
        let decl_label d =
          match d.Ast.decl_desc with
          | Ast.DFunc f -> "func " ^ Option.value f.func_name ~default:"?"
          | Ast.DVar v -> "var " ^ Option.value v.var_name ~default:"?"
          | Ast.DType t -> "type " ^ t.type_name
          | _ -> "decl"
        in
        let core_decls =
          List.map
            (fun typed_decl ->
              let d = Typed_ast.decl_ast typed_decl in
              try Core_lower.lower_typed_decl typed_decl with
              | Core_error.Core_error _ as exn -> raise exn
              | Failure msg ->
                  Core_error.errorf (Core_error.Stage Core_stage.Lower)
                    d.decl_loc
                    ~hint:
                      "Core lowering must either translate every module \
                       declaration or report the unsupported shape; silently \
                       dropping one would produce a partial module."
                    "lowering failed for %s in module %s: %s" (decl_label d)
                    m.name msg)
            (Typed_ast.program_decls typed_program)
        in
        Core_flatten.prefix_module_names m.name core_decls)
      modules
  in
  let main_core =
    Core_lower.lower_typed_program typed_main
    |> Core_flatten.rewrite_main_imported_type_names program
  in
  (* Import alias tables: main program's [import_aliases] + per-module
     [module_imports]. Built once via [Core_flatten] so downstream
     passes ([Core_mono], [Core_resolve]) share the same lookup. *)
  let import_aliases, module_imports =
    Core_flatten.build_import_tables_from_typecheck ~main_import_bindings
      modules
  in
  let full =
    Core_flatten.rewrite_canonical_module_type_names (module_core @ main_core)
  in
  (* Create a per-compilation registry and register type aliases into it
     before any subsequent pass runs. Mono matches param types against arg
     types structurally, so aliases like [Decoder[T] = pure (Value) -> Result[T, _]]
     must be expanded eagerly — otherwise a call site with a concrete
     [TyFunc] argument never matches a [TyNamed "Decoder"] parameter and
     no specialization is enqueued. The same registry is passed through
     emission so the backend sees the exact type facts used by the Core
     passes. *)
  let reg = Codegen_types.create_registry () in
  Core_flatten.register_types reg full;
  let full = Core_ffi_boundary.annotate_program ~reg full in
  let full = Core_list_layout.annotate_program ~reg full in
  let backend_input =
    run_core_passes ~on_stage ~on_stage_event ~reg ~import_aliases
      ~module_imports ~debug full
  in
  let output =
    emit_via_c_backend ~embed_runtime ~profile ~reg ~on_stage_event
      ~on_stage_json ~tail_observation_stages backend_input
  in
  (* Foreign metadata is pulled from the lowered program rather than the
     loaded-module AST so main-program FFI declarations are included too. *)
  let host = Platform.current () in
  let keep_flag = function None, _ -> true | Some tag, _ -> tag = host in
  let source_dir d =
    match d.Core.cd_loc.Ast.loc_file with
    | Some file -> Some (Modules.extract_directory file)
    | None -> None
  in
  let rec foreign_metadata d =
    match d.Core.cd_desc with
    | Core.CDFunc f -> (
        match f.cf_kind with
        | Core.CFForeign { link_flags; includes; _ } ->
            let link_flags =
              List.filter_map
                (fun entry ->
                  if keep_flag entry then Some (snd entry) else None)
                link_flags
            in
            let include_dirs =
              match (includes, source_dir d) with
              | [], _ | _, None -> []
              | _ :: _, Some dir -> [ dir ]
            in
            (link_flags, include_dirs)
        | _ -> ([], []))
    | Core.CDPrivate inner -> foreign_metadata inner
    | _ -> ([], [])
  in
  let link_flags, include_dirs =
    List.fold_left
      (fun (all_flags, all_dirs) d ->
        let flags, dirs = foreign_metadata d in
        (all_flags @ flags, all_dirs @ dirs))
      ([], []) full
  in
  let include_dirs = List.sort_uniq String.compare include_dirs in
  (output, link_flags, include_dirs)
