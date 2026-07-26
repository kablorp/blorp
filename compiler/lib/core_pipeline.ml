(** Core IR compilation pipeline.

    Normal source commands enter through [run_core_passes_from_post_mono] with
    Core produced by the Blorp-owned debug, desugar/SSA, mono, and post-mono
    list-layout stages. [run_core_passes] retains the full early chain only for
    the pinned bootstrap wrapper and direct in-memory compatibility tests.

    The complete compatibility pass chain is:
    1. [Core_debug] — erase or retain explicit debug blocks
    2. [Core_desugar] + [Core_ssa] — eliminate Core sugar and mutable locals
    3. [Core_mono] — monomorphize generic functions
    4. [Core_synth] — synthesize concrete builtin IR bodies post-mono
    5. [Core_match] — compile CMatchArms → CMatch decision trees
    6. [Core_trait_resolve] — rewrite trait methods/operators to impl calls
    7. [Core_resolve] — tag CCall by callee kind
    8. [Core_std_inline] — expand compiler-owned std wrappers at call sites
    9. [Core_tailrec] — make tail-recursive self-loops explicit
    10. [Core_string_pipeline] + [Core_collection_pipeline] +
       [Core_parallel_tensor_pipeline] + [Core_tensor_fusion] +
       [Core_tuple_sroa] — fuse compatible string/list/scoped tensor pipelines
       and tensor update expressions; scalar-replace non-escaping local tuples
       and narrow tuple-return call sites
    11. [Core_specialize] — type-dispatch builtins to CCast / concrete names
    12. backend handoff — default compilation gives pre-DCE Core to Blorp
    13. Blorp-owned function-reference adaptation + DCE — make eta adapters
       visible to Perceus, then prune unreachable emitted functions
    14. Blorp-owned consume-specialize pass
    15. Blorp-owned Perceus — insert explicit dup/drop operations
    16. Blorp-owned final tail — normal reuse, closure conversion, resource
       cleanup lowering, fairness checkpoints, codegen preparation, prepared
       reuse, and C artifact emission

    OCaml program-bearing callbacks stop at the pre-DCE handoff. CLI
    late-stage dumps/stops use Blorp Core JSON observation instead. Timing-only
    observation uses lightweight stage events. Normal C output always comes
    from the Blorp pre-DCE handoff.

    This module is the single OCaml owner of the remaining Core middle. *)

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

let blorp_tail_stage_name = function
  | ( Core_stage.Dce | Core_stage.ConsumeSpecialize | Core_stage.Perceus
    | Core_stage.Reuse | Core_stage.Closure | Core_stage.Final ) as stage ->
      Some (Core_stage.to_string stage)
  | Core_stage.Lower | Core_stage.Debug | Core_stage.Desugar | Core_stage.Mono
  | Core_stage.Synth | Core_stage.Match | Core_stage.TraitResolve
  | Core_stage.Resolve | Core_stage.StdInline | Core_stage.Tailrec
  | Core_stage.Fusion | Core_stage.Specialize ->
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

let pre_dce_program_json ~reg program =
  match Core_emit_blorp_c.program_json ~reg program with
  | Ok json -> json
  | Error error -> failwith (Core_emit_blorp_c.unsupported_to_string error)

let observe_blorp_tail_json ~reg ~(on_stage_event : on_stage_event)
    ~(on_stage_json : on_stage_json_callback) ~(stages : Core_stage.t list)
    (pre_dce : Core.core_program) =
  match stages with
  | [] -> ()
  | _ :: _ ->
      let core_json = pre_dce_program_json ~reg pre_dce in
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
      (** Pre-DCE Core handed to Blorp for DCE, consume specialization,
          Perceus, reuse, closure, resource/fairness, prepare, and emission. *)
}

(** Run C emission through the single Blorp backend path. Normal compilation
    hands off after specialization so Blorp owns DCE, consume specialization,
    Perceus, and the complete backend tail. Late-stage CLI observation uses
    [on_stage_json] over the Blorp-owned stages. *)
let emit_via_c_backend ~(embed_runtime : bool) ~(profile : bool)
    ~(reg : Codegen_types.registry) ~(on_stage_event : on_stage_event)
    ~(on_stage_json : on_stage_json_callback)
    ~(tail_observation_stages : Core_stage.t list)
    (backend_input : backend_core_input) : string =
  if not (core_stage_list_contains Core_stage.Dce tail_observation_stages) then
    on_stage_event Core_stage.Dce;
  observe_blorp_tail_json ~reg ~on_stage_event ~on_stage_json
    ~stages:tail_observation_stages backend_input.blorp_tail_input;
  let cfg =
    Core_emit_blorp_c.config_with_embed ~embed_runtime ~profile ~reg ()
  in
  let result =
    Core_emit_blorp_c.try_emit_core_program_string cfg
      backend_input.blorp_tail_input
  in
  if
    not (core_stage_list_contains Core_stage.Final tail_observation_stages)
  then on_stage_event Core_stage.Final;
  match result with Ok c_code -> c_code | Error reason -> failwith reason

(** Run the remaining OCaml middle starting from post-mono Core. This is the
    production semantic-worker entrypoint; debug, desugar/SSA, mono, and the
    post-mono list-layout annotation have already run in Blorp. *)
let run_core_passes_from_post_mono ?(import_aliases = Hashtbl.create 0)
    ?(module_imports = Hashtbl.create 0) ~(on_stage : on_stage_callback)
    ?(on_stage_event = no_op_on_stage_event) ~(reg : Codegen_types.registry)
    (prog : Core.core_program) : backend_core_input =
  let observe stage prog =
    on_stage_event stage;
    on_stage stage prog;
    prog
  in
  let run_stage stage pass prog = pass prog |> observe stage in
  let pre_dce =
    prog |> run_stage Core_stage.Synth (Core_synth.synthesize_program ~reg)
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
        |> Core_parallel_tensor_pipeline.fuse_program
        |> Core_tensor_fusion.fuse_program ~reg
        |> Core_tuple_sroa.rewrite_program ~reg)
    |> run_stage Core_stage.Specialize (Core_specialize.specialize_program ~reg)
  in
  { blorp_tail_input = pre_dce }

(** Run the complete compatibility Core chain from prepared Core. Production
    source compilation enters through [run_core_passes_from_post_mono]; this
    entrypoint remains for typed in-memory callers until they move to Blorp. *)
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
  let post_mono =
    prog |> observe Core_stage.Lower
    |> run_stage Core_stage.Debug (Core_debug.lower_program ~enabled:debug)
    |> run_stage Core_stage.Desugar (fun p ->
        p |> Core_desugar.desugar_program |> Core_ssa.desugar_mut_program)
    |> run_stage Core_stage.Mono (fun p ->
        p
        |> Core_mono.monomorphize_program ~reg ~import_aliases ~module_imports
        |> Core_list_layout.annotate_program ~reg)
  in
  run_core_passes_from_post_mono ~import_aliases ~module_imports ~on_stage
    ~on_stage_event ~reg post_mono

let max_definition_id current candidate =
  match (current, candidate) with
  | current, None -> current
  | None, Some id -> Some id
  | Some current_id, Some id -> Some (max current_id id)

let max_function_definition_id current func =
  max_definition_id current (Typed_ast.func_callable_id func)

let rec max_typed_decl_definition_id current decl =
  let current =
    match Typed_ast.decl_view decl with
    | Typed_ast.DeclFunction func ->
        max_function_definition_id current func
    | Typed_ast.DeclImpl impl ->
        List.fold_left max_function_definition_id current
          (Typed_ast.impl_methods impl)
    | Typed_ast.DeclPrivate inner ->
        max_typed_decl_definition_id current inner
    | Typed_ast.DeclVar _ | Typed_ast.DeclRecord _
    | Typed_ast.DeclTypeAlias _ | Typed_ast.DeclOther ->
        current
  in
  match (Typed_ast.decl_ast decl).Ast.decl_desc with
  | Ast.DType type_decl ->
      List.fold_left
        (fun max_id variant ->
          max_definition_id max_id variant.Ast.variant_def_id)
        current type_decl.type_variants
  | Ast.DFunc _ | Ast.DRecord _ | Ast.DVar _ | Ast.DImport _
  | Ast.DPrivate _ | Ast.DTrait _ | Ast.DImpl _ | Ast.DTypeAlias _ ->
      current

(** Reset per-compilation counters while reserving the source identity range
    carried by typed frontend artifacts. Generated globals, lambdas, and
    specializations must never reuse a source function or constructor DefId. *)
let reset_core_counters_for_typed_programs typed_programs =
  let session = Session.current () in
  Session.reset_core_counters session;
  let max_source_id =
    List.fold_left
      (fun max_id program ->
        List.fold_left max_typed_decl_definition_id max_id
          (Typed_ast.program_decls program))
      None typed_programs
  in
  Option.iter
    (fun source_id -> Session.reserve_def_id_floor session (source_id + 1))
    max_source_id

let compile_typed ?(embed_runtime = false) ?(profile = false) ?(debug = false)
    ?on_stage ?(on_stage_event = no_op_on_stage_event)
    ?(on_stage_json = no_op_on_stage_json) ?(tail_observation_stages = [])
    ?(check_invariants = false) (typed_program : Typed_ast.program) : string =
  let user_on_stage = Option.value ~default:no_op_on_stage on_stage in
  let on_stage = make_stage_hook ~check_invariants ~user:user_on_stage in
  reset_core_counters_for_typed_programs [ typed_program ];
  let core_prog = Core_lower.lower_typed_program typed_program in
  (* Share one registry across mono and emit so type aliases registered at
     either end are visible to both. See [compile_with_modules] for the
     rationale. *)
  let reg = Codegen_types.create_registry () in
  let core_prog = Core_flatten.rewrite_canonical_module_type_names core_prog in
  Core_registry.register_types reg core_prog;
  let core_prog = Core_ffi_boundary.annotate_program ~reg core_prog in
  let core_prog = Core_list_layout.annotate_program ~reg core_prog in
  let backend_input =
    run_core_passes ~on_stage ~on_stage_event ~reg ~debug core_prog
  in
  emit_via_c_backend ~embed_runtime ~profile ~reg
    ~on_stage_event ~on_stage_json ~tail_observation_stages backend_input

type typed_module_input = {
  typed_module_name : string;
  typed_module_program : Typed_ast.program;
  typed_module_import_bindings : Session.import_binding list;
}

type prepared_typed_program = {
  prepared_core : Core.core_program;
  prepared_registry : Codegen_types.registry;
  prepared_import_aliases : (string, string * string) Hashtbl.t;
  prepared_module_imports :
    (string, (string, string * string) Hashtbl.t) Hashtbl.t;
}

let typed_module_input_of_loaded_module (loaded : Modules.loaded_module) =
  let typed_module_program =
    match loaded.typed_decls with
    | Some typed_program -> typed_program
    | None ->
        Core_error.errorf (Core_error.Stage Core_stage.Lower) Ast.dummy_loc
          ~hint:
            "Pipeline.ensure_modules_typed must type-check every loaded module \
             before Core lowering. If this came from a direct Core_pipeline \
             call, use a high-level Pipeline entrypoint or provide an explicit \
             typed module input."
          "module %s reached Core lowering without typed declarations"
          loaded.name
  in
  {
    typed_module_name = loaded.name;
    typed_module_program;
    typed_module_import_bindings =
      Option.value ~default:[] loaded.typed_import_bindings;
  }

let typed_decl_label typed_decl =
  match (Typed_ast.decl_ast typed_decl).Ast.decl_desc with
  | Ast.DFunc f -> "func " ^ Option.value f.func_name ~default:"?"
  | Ast.DVar v -> "var " ^ Option.value v.var_name ~default:"?"
  | Ast.DType t -> "type " ^ t.type_name
  | _ -> "decl"

let lower_typed_module ~module_programs (module_input : typed_module_input) =
  let core_decls =
    List.map
      (fun typed_decl ->
        let decl = Typed_ast.decl_ast typed_decl in
        try Core_lower.lower_typed_decl typed_decl with
        | Core_error.Core_error _ as exn -> raise exn
        | Failure msg ->
            Core_error.errorf (Core_error.Stage Core_stage.Lower) decl.decl_loc
              ~hint:
                "Core lowering must either translate every module declaration \
                 or report the unsupported shape; silently dropping one would \
                 produce a partial module."
              "lowering failed for %s in module %s: %s"
              (typed_decl_label typed_decl)
              module_input.typed_module_name msg)
      (Typed_ast.program_decls module_input.typed_module_program)
  in
  Core_flatten.prefix_module_names
    ~import_bindings:module_input.typed_module_import_bindings ~module_programs
    module_input.typed_module_name core_decls

(** Restore the resource-cleanup metadata carried by a post-typecheck program.
    OCaml typechecking registers this metadata directly, while decoded Blorp
    typed programs arrive without those process-local side effects. Keeping
    restoration at the typed-to-Core boundary makes both inputs equivalent. *)
let register_typechecked_resource_cleanups ~module_name typed_program =
  let session = Session.current () in
  let register type_name cleanup =
    Session.register_resource_cleanup session ~type_name cleanup
  in
  let rec visit_decl (decl : Ast.decl) =
    match decl.decl_desc with
    | Ast.DPrivate inner -> visit_decl inner
    | Ast.DType type_decl when type_decl.type_is_resource ->
        Option.iter
          (fun cleanup ->
            register type_decl.type_name cleanup;
            let canonical_name =
              Types.canonical_module_type_name ~module_path:module_name
                type_decl.type_name
            in
            if
              module_name <> ""
              && not (String.equal canonical_name type_decl.type_name)
            then
              register canonical_name cleanup)
          type_decl.type_resource_cleanup
    | _ -> ()
  in
  Typed_ast.program_ast typed_program |> List.iter visit_decl

(** Build the explicit lowered input for the semantic middle. This is the
    shared boundary used by the current in-process pipeline and the temporary
    OCaml worker. It deliberately takes typed modules rather than consulting
    the process-global module cache. *)
let prepare_typed_with_module_inputs ?(main_import_bindings = [])
    ?(main_module_name = "") ~(modules : typed_module_input list)
    (typed_main : Typed_ast.program) =
  reset_core_counters_for_typed_programs
    (typed_main :: List.map (fun input -> input.typed_module_program) modules);
  List.iter
    (fun module_input ->
      register_typechecked_resource_cleanups
        ~module_name:module_input.typed_module_name
        module_input.typed_module_program)
    modules;
  register_typechecked_resource_cleanups ~module_name:main_module_name typed_main;
  let module_programs =
    List.map
      (fun module_input ->
        ( module_input.typed_module_name,
          Typed_ast.program_ast module_input.typed_module_program ))
      modules
  in
  let module_core =
    List.concat_map (lower_typed_module ~module_programs) modules
  in
  let main_core =
    Core_lower.lower_typed_program typed_main
    |> Core_flatten.rewrite_main_imported_type_names_from_bindings
         ~main_import_bindings ~module_programs
  in
  let module_bindings =
    List.map
      (fun module_input ->
        ( module_input.typed_module_name,
          module_input.typed_module_import_bindings ))
      modules
  in
  let prepared_import_aliases, prepared_module_imports =
    Core_imports.tables_of_bindings ~main_import_bindings
      module_bindings
  in
  let full =
    Core_flatten.rewrite_canonical_module_type_names (module_core @ main_core)
  in
  let prepared_registry = Codegen_types.create_registry () in
  Core_registry.register_types prepared_registry full;
  let full = Core_ffi_boundary.annotate_program ~reg:prepared_registry full in
  let prepared_core =
    Core_list_layout.annotate_program ~reg:prepared_registry full
  in
  {
    prepared_core;
    prepared_registry;
    prepared_import_aliases;
    prepared_module_imports;
  }

let foreign_metadata_for_program (program : Core.core_program) =
  let host = Platform.current () in
  let keep_flag = function None, _ -> true | Some tag, _ -> tag = host in
  let source_dir decl =
    match decl.Core.cd_loc.Ast.loc_file with
    | Some file -> Some (Modules.extract_directory file)
    | None -> None
  in
  let rec foreign_metadata decl =
    match decl.Core.cd_desc with
    | Core.CDFunc f -> (
        match f.cf_kind with
        | Core.CFForeign { link_flags; includes; _ } ->
            let link_flags =
              List.filter_map
                (fun entry -> if keep_flag entry then Some (snd entry) else None)
                link_flags
            in
            let include_dirs =
              match (includes, source_dir decl) with
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
      (fun (all_flags, all_dirs) decl ->
        let flags, dirs = foreign_metadata decl in
        (all_flags @ flags, all_dirs @ dirs))
      ([], []) program
  in
  (link_flags, List.sort_uniq String.compare include_dirs)

let compile_typed_with_module_inputs ?(main_import_bindings = [])
    ~(modules : typed_module_input list)
    ?(embed_runtime = true) ?(profile = false) ?(debug = false) ?on_stage
    ?(on_stage_event = no_op_on_stage_event)
    ?(on_stage_json = no_op_on_stage_json) ?(tail_observation_stages = [])
    ?(check_invariants = false) (typed_main : Typed_ast.program) :
    string * string list * string list =
  let user_on_stage = Option.value ~default:no_op_on_stage on_stage in
  let on_stage = make_stage_hook ~check_invariants ~user:user_on_stage in
  let {
    prepared_core;
    prepared_registry;
    prepared_import_aliases;
    prepared_module_imports;
  } =
    prepare_typed_with_module_inputs ~main_import_bindings ~modules typed_main
  in
  (* Extract metadata before emission so [prepared_core] is no longer needed
     while the external Blorp emitter decodes its own Core representation. On
     compiler-sized inputs, retaining both graphs at that boundary can exceed
     a constrained build runner's memory. *)
  let link_flags, include_dirs =
    foreign_metadata_for_program prepared_core
  in
  let backend_input =
    run_core_passes ~on_stage ~on_stage_event
      ~reg:prepared_registry ~import_aliases:prepared_import_aliases
      ~module_imports:prepared_module_imports ~debug prepared_core
  in
  let output =
    emit_via_c_backend ~embed_runtime ~profile
      ~reg:prepared_registry ~on_stage_event ~on_stage_json
      ~tail_observation_stages backend_input
  in
  (output, link_flags, include_dirs)

(** Compile a typed AST program with module support from the current session.
    This compatibility entrypoint converts loaded modules to explicit inputs;
    all lowering and pass behavior is shared with the semantic worker. *)
let compile_typed_with_modules ?(main_import_bindings = [])
    ?(embed_runtime = true) ?(profile = false) ?(debug = false) ?on_stage
    ?(on_stage_event = no_op_on_stage_event)
    ?(on_stage_json = no_op_on_stage_json) ?(tail_observation_stages = [])
    ?(check_invariants = false) (typed_main : Typed_ast.program) :
    string * string list * string list =
  let modules =
    Modules.get_all_modules () |> List.map typed_module_input_of_loaded_module
  in
  compile_typed_with_module_inputs ~main_import_bindings ~modules
    ~embed_runtime ~profile ~debug ?on_stage ~on_stage_event ~on_stage_json
    ~tail_observation_stages ~check_invariants typed_main
