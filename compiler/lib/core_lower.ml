(** Lowering from typed AST to Core IR.

    This module is the only AST-to-Core boundary. It translates typed
    expressions, declarations, and programs into Core while preserving the
    type and source-location information later passes depend on.

    {1 Invariants}

    - The public lowering boundary consumes [Typed_ast] values. Raw [Ast]
      payloads are available only inside validated typed wrappers or for
      module-local synthetic nodes that are immediately validated before
      recursive lowering.
    - Lowering is {b mechanical}: no optimization, no RC insertion, no
      constant folding. One-to-one translation preserving semantics.
    - Sugar that belongs in Core ([ERecordUpdate], [EStringInterp]) is lowered
      to explicit Core nodes. Direct [?=] propagation is desugared here while
      typed AST context is still available.

    {1 Block lowering}

    [EBlock] is the most interesting case. It becomes a nested [CLet]/[CSeq]
    chain:

    {v
    { var x = 5; print(x); x + 1 }
    ⟶
    CLet("x", 5, CSeq(print(x), x + 1))
    v}

    - [EVarDecl] creates a [CLet] scoping over the rest of the block.
    - [ETupleDestruct] desugars inline to Core field reads:
      [let __dt = e in let a = CField(__dt, "0") in let b = CField(__dt, "1") in rest].
    - Any other expression becomes the [CSeq] head. The final block element
      is the block's result.

    {1 What we deliberately defer}

    - Hygienic variable IDs: generated temporaries still rely on distinct
      names. [Core.var.vuniq] remains available for a future alpha-renaming
      pass.
    - [CLambda] captures: the body is lowered, but the captures list is
      populated by a later "captures" pass, not here.
    - Decision-tree match compilation: [CMatchArms] carries raw
      [Ast.pattern]; [Core_match] compiles it to [CMatch] downstream.
    - RC insertion: no [CDup]/[CDrop]. The Blorp Perceus pass inserts them. *)

open Ast
module TA = Typed_ast

(* ============================================================================
   Fresh-name counters for generated temporaries
   ============================================================================ *)

(** Fresh-name counters live on [Session.t] (T1.4 — 2026-04-21).
    Rationale: these accumulate per-compilation scratch state. Before
    the migration they were module-level [ref 0] with per-call reset
    functions that [lower_program] invoked; the question-bind counter didn't
    reset and silently leaked between compilations in long-lived
    processes (LSP, batch test runner). Moving to [Session] fixes
    the leak and makes the shared-state lifetime explicit. *)

let fresh_destruct_name () =
  let s = Session.current () in
  let n = s.lower_destruct_counter in
  s.lower_destruct_counter <- n + 1;
  Printf.sprintf "__dt_%d" n

let fresh_param_name () =
  let s = Session.current () in
  let n = s.lower_param_counter in
  s.lower_param_counter <- n + 1;
  Printf.sprintf "__p_%d" n

(** Generated temporary for direct [?=] lowering. *)
let fresh_question_bind_name () =
  let s = Session.current () in
  let n = s.lower_question_bind_counter in
  s.lower_question_bind_counter <- n + 1;
  Printf.sprintf "__qb_%d" n

let fresh_resource_name () =
  let s = Session.current () in
  let n = s.lower_resource_counter in
  s.lower_resource_counter <- n + 1;
  Printf.sprintf "__resource_%d" n

let fresh_timeout_name label =
  let s = Session.current () in
  let n = s.lower_destruct_counter in
  s.lower_destruct_counter <- n + 1;
  Printf.sprintf "__timeout_%s_%d" label n

let fresh_task_scope_id () =
  let s = Session.current () in
  let n = s.lower_task_scope_counter in
  s.lower_task_scope_counter <- n + 1;
  Core.TaskScopeId n

let current_task_scope_id () =
  let s = Session.current () in
  Core.TaskScopeId s.lower_current_task_scope_id

let with_current_task_scope scope f =
  let s = Session.current () in
  let previous = s.lower_current_task_scope_id in
  s.lower_current_task_scope_id <- Core.task_scope_id_to_int scope;
  match f () with
  | result ->
      s.lower_current_task_scope_id <- previous;
      result
  | exception exn ->
      s.lower_current_task_scope_id <- previous;
      raise exn

let fresh_loop_tuple_name () =
  let s = Session.current () in
  let n = s.lower_destruct_counter in
  s.lower_destruct_counter <- n + 1;
  Printf.sprintf "__loop_tuple_%d" n

(** A pattern name is a wildcard ("_") if it discards its match — used
    by tuple-destructure lowering to skip the binding entirely so
    scope-exit cleanup doesn't try to [blorp_release(_)]. *)
let is_wildcard_name (name : string) : bool = name = "_"

type carrier_kind = CarrierOption | CarrierResult

let carrier_kind_of_type ty =
  match Codegen_types.normalize_type ty with
  | Ast.TyNamed ("Option", [ _ ]) -> Some CarrierOption
  | Ast.TyNamed ("Result", [ _; _ ]) -> Some CarrierResult
  | _ -> None

let require_carrier_kind ~loc ~hint ~what ty =
  match carrier_kind_of_type ty with
  | Some kind -> kind
  | None ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc ~hint
        "cannot classify %s carrier type: %s" what (Types.type_to_string ty)

let carrier_success_type_of_type ty =
  match Codegen_types.normalize_type ty with
  | Ast.TyNamed ("Option", [ inner ]) -> Some inner
  | Ast.TyNamed ("Result", [ ok; _ ]) -> Some ok
  | _ -> None

let require_carrier_success_type ~loc ~hint ~what ty =
  match carrier_success_type_of_type ty with
  | Some success_ty -> success_ty
  | None ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc ~hint
        "cannot classify %s carrier payload type: %s" what
        (Types.type_to_string ty)

let carrier_success_ctor = function
  | CarrierOption -> "Some"
  | CarrierResult -> "Ok"

let carrier_failure_type_of_type ty =
  match Codegen_types.normalize_type ty with
  | Ast.TyNamed ("Result", [ _; err ]) -> Some err
  | _ -> None

let require_carrier_failure_type ~loc ~hint ~what ty =
  match carrier_failure_type_of_type ty with
  | Some err_ty -> err_ty
  | None ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc ~hint
        "cannot classify %s carrier error type: %s" what
        (Types.type_to_string ty)

let carrier_failure_pattern kind failure_name =
  match kind with
  | CarrierOption -> Ast.PatConstructor ("None", [])
  | CarrierResult -> Ast.PatConstructor ("Err", [ Ast.PatVar failure_name ])

let builtin_call ~loc name args ret_ty =
  let dummy = { Core.desc = CVoid; ty = Ast.TyNamed ("Void", []); loc } in
  { Core.desc = CCall (CKBuiltin name, dummy, args); ty = ret_ty; loc }

let carrier_failure_expr ~loc ~kind ~carrier_ty ~failure_name ~failure_ty =
  match kind with
  | CarrierOption -> builtin_call ~loc "blorp_option_none" [] carrier_ty
  | CarrierResult ->
      let err_ref =
        { Core.desc = CVar (Core.Var.named failure_name); ty = failure_ty; loc }
      in
      builtin_call ~loc "blorp_result_err" [ err_ref ] carrier_ty

let resource_cleanup_metadata ty =
  match Codegen_types.normalize_type ty |> Types.head_resolve with
  | Ast.TyNamed (name, _) ->
      Session.find_resource_cleanup (Session.current ()) name
  | _ -> None

let resource_source_parts ty =
  match Codegen_types.normalize_type ty |> Types.head_resolve with
  | Ast.TyNamed (name, [ resource_ty; error_ty ])
    when Type_name_metadata.is_resource_source_name name ->
      Some (resource_ty, error_ty)
  | _ -> None

let resource_cleanup_call ~loc resource_ty resource_var =
  let void_ty = Ast.TyNamed ("Void", []) in
  let resource_ref = { Core.desc = CVar resource_var; ty = resource_ty; loc } in
  let callee_ty =
    Ast.TyFunc { params = [ resource_ty ]; return = void_ty; is_pure = false }
  in
  match resource_cleanup_metadata resource_ty with
  | Some (ResourceCleanupBuiltin c_name) ->
      {
        Core.desc =
          CCall
            ( CKBuiltin c_name,
              { Core.desc = CVoid; ty = void_ty; loc },
              [ resource_ref ] );
        ty = void_ty;
        loc;
      }
  | None ->
      let callee =
        { Core.desc = CVar (Core.Var.named "close"); ty = callee_ty; loc }
      in
      {
        Core.desc = CCall (CKUnknown, callee, [ resource_ref ]);
        ty = void_ty;
        loc;
      }

(* ============================================================================
   Type resolution
   ============================================================================ *)

(** Get the type of a typed AST node.

    Post-typecheck invariant: every typed AST expression carries
    [expr_type = Some _]. Any leak here is a typechecker bug. Raise with
    source location so the upstream leak is findable.

    Historically this branch fell back to [Void] to keep downstream lowering
    non-destructive when the test runner's [is_genuine_type_error] filter
    suppressed typecheck errors. Both the filter and its cover-up fallback
    are now gone — enforcing the invariant catches future leaks. *)
let require_final_type ~(loc : Ast.loc) ~(context : string) (ty : type_expr) :
    type_expr =
  if Types.contains_meta ty then
    Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
      ~hint:
        "Core lowering only accepts finalized semantic types. This usually \
         means inference returned a partially zonked AST."
      "inference metavariable reached Core lowering in %s: %s" context
      (Types.type_to_string ty)
  else ty

let typed_ast_error (err : Typed_ast.error) =
  match err with
  | MissingExprType { loc; _ } ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "Core lowering expects typecheck to populate expr_type on every \
           expression. This usually means a typecheck path returned a \
           partially typed AST."
        "untyped expression reached Core lowering"
  | MissingExprTypeInfo { loc; context } ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "Core lowering expects typecheck to populate structured type \
           metadata on every expression. Route synthetic typed expressions \
           through Typed_ast.of_ast_expr_with_type_info instead of setting raw \
           typed payloads directly."
        "partially typed expression reached Core lowering in %s" context
  | UnfinalizedExprType { loc; context; ty }
  | UnfinalizedType { loc; context; ty } ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "Core lowering only accepts finalized semantic types. This usually \
           means inference returned a partially zonked AST."
        "inference metavariable reached Core lowering in %s: %s" context
        (Types.type_to_string ty)
  | MissingRequiredType { loc; context } ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "Typed declarations must carry all required type annotations before \
           Core lowering. Check signature registration and inference."
        "%s missing type" context
  | InvalidTypeInfo { loc; context; message } ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "Typed expression metadata must keep semantic, value-slot, and \
           widening information coherent before Core lowering."
        "invalid typed expression info in %s: %s" context message

let require_typed_expr (e : expr) : TA.expr =
  match TA.of_ast_expr e with
  | Ok typed -> typed
  | Error err -> typed_ast_error err

let typed_expr_desc (typed : TA.expr) : TA.expr_desc =
  match TA.expr_desc typed with
  | Ok desc -> desc
  | Error err -> typed_ast_error err

let type_of_child_expr (e : TA.expr) : type_expr = TA.semantic_type e
let ty_int = TyNamed ("Int", [])
let ty_module = TyNamed ("Module", [])

let typed_expr_with_type ?(context = "synthetic Core lowering expression")
    ?source_ty ?origin ?resolved_call ?proofs (expr : expr) (ty : type_expr) :
    TA.expr =
  match
    TA.of_ast_expr_with_type_info ~context ?source_ty ?origin ?resolved_call
      ?proofs ~semantic_ty:ty ~value_ty:ty ~widening:(Keep ty) expr
  with
  | Ok typed -> typed
  | Error err -> typed_ast_error err

let typed_ident_expr ~(loc : Ast.loc) (name : string) (ty : type_expr) : TA.expr
    =
  typed_expr_with_type ~context:"synthetic Core lowering identifier"
    (Ast.untyped_expr ~loc (EIdent name))
    ty

let direct_call_core_def_id (call : resolved_call) : int option =
  match call.call_target with
  | CallDirect { callable_id; origin = CallableLocal; _ } -> Some callable_id
  | CallDirect
      {
        origin =
          ( CallableImported _ | CallableBuiltin | CallableForeign
          | CallableConstructor _ | CallableImplMethod );
        _;
      } ->
      None
  | CallTraitMethod { callable_id = Some callable_id; _ } -> Some callable_id
  | CallTraitMethod { callable_id = None; _ } | CallClosure _ -> None

let selected_direct_call_kind ~(call : TA.expr) (callee_core : Core.core) :
    Core.call_kind =
  match (TA.expr_resolved_call call, callee_core.desc) with
  | Some resolved, CVar v -> (
      match direct_call_core_def_id resolved with
      | None -> CKUnknown
      | Some callable_id -> (
          match v.vdef_id with
          | Some existing when existing <> callable_id ->
              Core_error.errorf (Core_error.Stage Core_stage.Lower)
                (TA.loc call)
                ~hint:
                  "Inference attached conflicting callable identities to one \
                   call. Keep the typed resolved_call metadata as the \
                   authority and fix the stale encoded callee name."
                "conflicting callable ids for lowered call '%s': callee \
                 carried %d but resolved_call carried %d"
                v.vname existing callable_id
          | Some _ | None -> CKSelectedDirect callable_id))
  | ( Some ({ call_syntax = CallQualified _; _ } as resolved),
      CField ({ desc = CVar v; ty; _ }, field) )
    when Types.types_equal ty (TyNamed ("Module", [])) -> (
      match direct_call_core_def_id resolved with
      | None -> CKUnknown
      | Some callable_id -> (
          match v.vdef_id with
          | Some existing when existing <> callable_id ->
              Core_error.errorf (Core_error.Stage Core_stage.Lower)
                (TA.loc call)
                ~hint:
                  "Inference attached conflicting callable identities to one \
                   qualified call. Keep the typed resolved_call metadata as \
                   the authority and fix the stale module-alias metadata."
                "conflicting callable ids for lowered qualified call '.%s': \
                 module alias carried %d but resolved_call carried %d"
                field existing callable_id
          | Some _ | None -> CKSelectedDirect callable_id))
  | _ -> CKUnknown

let is_module_sentinel_type (ty : type_expr) : bool =
  Types.types_equal ty ty_module

let peeled_array_type elem dims =
  match dims with
  | [ _single_dim ] -> elem
  | _ :: rest_dims -> Types.ty_array elem rest_dims
  | [] -> elem

let unsupported_iterable ~loc ty =
  Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
    ~hint:
      "The typechecker should reject non-iterable values before Core lowering. \
       If this is a valid source program, add the missing iterable type rule \
       to inference instead of guessing here."
    "unsupported for-loop iterable type: %s" (Types.type_to_string ty)

let elem_type_of_iterable ~loc (ty : type_expr) : type_expr =
  match ty with
  | TyNamed ("List", [ elem ]) -> elem
  | _ when Types.is_array_type ty -> (
      match Types.array_parts ty with
      | Some (elem, dims) -> peeled_array_type elem dims
      | None -> unsupported_iterable ~loc ty)
  | TyNamed ("Dict", [ key; _ ]) -> key
  | TyNamed ("Set", [ elem ]) -> elem
  | TyNamed ("String", []) -> TyNamed ("Char", [])
  | TyNamed ("Range", []) -> ty_int
  | TyNamed ("Range", [ elem ]) -> elem
  | TyNamed ("Channel", [ elem ]) -> elem
  | TyNamed (name, [ elem ]) when Type_name_metadata.is_stream_name name -> elem
  | _ -> unsupported_iterable ~loc ty

let enumerate_elem_type ~loc (coll_ty : type_expr) : type_expr * type_expr =
  match Types.array_parts coll_ty with
  | Some (elem, dims) ->
      let peeled = peeled_array_type elem dims in
      let idx =
        match dims with
        | TyConstInt n :: _ when n > 0 -> TyRange (TyConstInt n)
        | TyVar n :: _ -> TyRange (TyVar n)
        | _ -> ty_int
      in
      (idx, peeled)
  | None ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "enumerate is a tensor/array loop combinator. For List enumeration, \
           use the std/list enumerate function outside the special for-loop \
           lowering path."
        "enumerate requires an array, got %s"
        (Types.type_to_string coll_ty)

let indices_elem_type ~loc (coll_ty : type_expr) : type_expr =
  match Types.array_parts coll_ty with
  | Some (_, dims) -> (
      match dims with
      | TyConstInt n :: _ when n > 0 -> TyRange (TyConstInt n)
      | TyVar n :: _ -> TyRange (TyVar n)
      | _ -> ty_int)
  | None ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:"indices is a tensor/array loop combinator."
        "indices requires an array, got %s"
        (Types.type_to_string coll_ty)

let loop_binder_for (name : string) (loop_ty : type_expr) : Core.loop_binder =
  Core.loop_binder_named name loop_ty

let fresh_loop_internal_name (base : string) (forbidden : string list) : string
    =
  if not (List.exists (String.equal base) forbidden) then base
  else
    let s = Session.current () in
    let n = s.lower_destruct_counter in
    s.lower_destruct_counter <- n + 1;
    Printf.sprintf "%s_%d" base n

let bind_loop_view_fields ~loc
    (fields : (string * Ast.type_expr * Core.core) list) (body : Core.core) :
    Core.core =
  let rec wrap = function
    | [] -> body
    | (name, _, _) :: rest when is_wildcard_name name -> wrap rest
    | (name, field_ty, field_rhs) :: rest ->
        let inner = wrap rest in
        let bind =
          {
            Core.bind_var = Core.Var.named name;
            bind_mut = false;
            bind_ty = field_ty;
            bind_rhs = field_rhs;
          }
        in
        { Core.desc = CLet (bind, inner); ty = inner.ty; loc }
  in
  wrap fields

let lower_duration_timeout_milliseconds (duration : Core.core) : Core.core =
  let loc = duration.loc in
  let module B = Core.Build in
  let microseconds_per_millisecond = 1000 in
  let duration_name = fresh_timeout_name "duration" in
  let microseconds_name = fresh_timeout_name "microseconds" in
  let whole_ms_name = fresh_timeout_name "whole_ms" in
  let duration_microseconds = B.var ~loc ~ty:ty_int duration_name in
  let microseconds_ref = B.var ~loc ~ty:ty_int microseconds_name in
  let whole_ms_rhs =
    B.div microseconds_ref (B.lit_int ~loc microseconds_per_millisecond)
  in
  let whole_ms_ref = B.var ~loc ~ty:ty_int whole_ms_name in
  let rounded_ms =
    B.if_
      ~cond:
        (B.eq
           (B.modulo microseconds_ref
              (B.lit_int ~loc microseconds_per_millisecond))
           (B.lit_int ~loc 0))
      ~then_:whole_ms_ref
      ~else_:(B.add whole_ms_ref (B.lit_int ~loc 1))
  in
  let positive_ms =
    B.let_ whole_ms_name ~ty:ty_int ~rhs:whole_ms_rhs ~body:rounded_ms
  in
  let clamped_ms =
    B.if_
      ~cond:(B.le microseconds_ref (B.lit_int ~loc 0))
      ~then_:(B.lit_int ~loc 0) ~else_:positive_ms
  in
  let converted =
    B.let_ microseconds_name ~ty:ty_int ~rhs:duration_microseconds
      ~body:clamped_ms
  in
  B.let_ duration_name ~ty:duration.ty ~rhs:duration ~body:converted

(* ============================================================================
   Lowering
   ============================================================================ *)

let rec lower_typed_expr_core (typed : TA.expr) : Core.core =
  let ty = TA.semantic_type typed in
  let loc = TA.loc typed in
  let mk d = { Core.desc = d; ty; loc } in
  match typed_expr_desc typed with
  (* === Leaves === *)
  | TA.EIdent name ->
      (* A3.3 UFCS handoff: [infer.ml] encodes the selected overload's
         [ol_def_id] into the mangled identifier as a ["#<id>"] suffix
         when UFCS dispatch firmly selects a single overload. Strip the
         suffix here into [vdef_id]; the [vname] stored on the [var]
         carries only the clean form so [Core_resolve.parse_ufcs_name]
         and [env.user_funcs] lookup see the ordinary mangled string.
         Non-UFCS idents and UFCS idents from the fallback branch (no
         selection) have no suffix and lower to [vdef_id = None]. *)
      let vname, vdef_id =
        if String.length name > 7 && String.sub name 0 7 = "__ufcs_" then
          match String.index_opt name '#' with
          | Some hash_idx -> (
              let clean = String.sub name 0 hash_idx in
              let id_str =
                String.sub name (hash_idx + 1)
                  (String.length name - hash_idx - 1)
              in
              match int_of_string_opt id_str with
              | Some id -> (clean, Some id)
              | None -> (name, None))
          | None -> (name, None)
        else (name, None)
      in
      mk (CVar { vname; vuniq = 0; vdef_id })
  | TA.ELiteral lit -> mk (CLit lit)
  | TA.EVoid -> mk CVoid
  | TA.EBreak -> mk CBreak
  | TA.EContinue -> mk CContinue
  | TA.EBuiltin _ ->
      (* Whole-function builtin bodies should be [FuncBuiltinBody] before
         lowering. [EBuiltin] reaching expression lowering means a parser-level
         placeholder escaped the function-body construction boundary. *)
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "builtin bodies must be represented as FuncBuiltinBody before Core \
           lowering"
        "EBuiltin reached lowering — placeholder for compiler-provided bodies"
  (* === Operators === *)
  | TA.EBinary (op, l, r) ->
      mk (CBin (op, lower_child_expr l, lower_child_expr r))
  | TA.EUnary (op, x) -> mk (CUn (op, lower_child_expr x))
  | TA.ELogical (op, l, r) ->
      mk (CLog (op, lower_child_expr l, lower_child_expr r))
  | TA.EAscription (inner, _) -> lower_child_expr inner
  | TA.EOpaqueInto (_, inner) | TA.EOpaqueFrom (_, inner) ->
      { (lower_child_expr inner) with ty }
  (* === Call / Field === *)
  | TA.ECall (callee, args) -> (
      (* Phase 4.2 element-wise tensor lift: a unary call to a pure scalar
         function on a tensor arg (with a tensor-valued return from inference)
         routes directly to [blorp_vector_<op>_<suffix>]. Done here — before
         resolve mangles the callee name into import-aliased, trait-impl, or
         builtin-prefixed forms — so the dispatch doesn't have to reverse-
         engineer source names from mangled strings. *)
      match try_elementwise_lift ty callee args with
      | Some core -> core
      | None ->
          let callee_core = lower_child_expr callee in
          let call_kind = selected_direct_call_kind ~call:typed callee_core in
          (* Lowering normally emits [CKUnknown], but typed resolved_call
             metadata can attach a selected direct callable id as
             [CKSelectedDirect]. [Core_mono] may use that id before
             [Core_resolve] replaces it with the canonical [CKUser] target. *)
          mk (CCall (call_kind, callee_core, List.map lower_child_expr args)))
  | TA.EFieldAccess (obj, name) ->
      (* Module alias (`M.func`): inference represents `M` with the explicit
         [TyNamed "Module"] sentinel. Lowering accepts that typed sentinel but
         does not infer it here; an untyped alias object is a typechecker leak. *)
      let obj_core =
        match typed_expr_desc obj with
        | TA.EIdent ident_name
          when is_module_sentinel_type (type_of_child_expr obj) ->
            {
              Core.desc = CVar (Core.Var.named ident_name);
              ty = ty_module;
              loc = TA.loc obj;
            }
        | _ -> lower_child_expr obj
      in
      mk (CField (obj_core, name))
  (* === Control flow === *)
  | TA.EIf (cond, then_e, Some else_e) ->
      mk
        (CIf
           ( lower_child_expr cond,
             lower_child_expr then_e,
             lower_child_expr else_e ))
  | TA.EIf (cond, then_e, None) ->
      let ty_void = TyNamed ("Void", []) in
      let else_void = { Core.desc = CVoid; ty = ty_void; loc } in
      mk (CIf (lower_child_expr cond, lower_child_expr then_e, else_void))
  | TA.EMatch (scrut, cases) ->
      let arms =
        List.map
          (fun c -> (c.TA.case_pattern, lower_child_expr c.case_body))
          cases
      in
      mk (CMatchArms (lower_child_expr scrut, arms))
  | TA.EWhile (cond, body) ->
      mk (CWhile (lower_child_expr cond, lower_child_expr body))
  | TA.EFor (var, iter, body) -> (
      (* Consume explicit loop-view producers from inference. Inference already
         resolved the source producer, typed the element, and set up bounds
         proving for the loop body; lowering only rewrites the CFor to an
         equivalent index-based form so the emitter and downstream passes see a
         normal integer-range loop with a synthesized tuple binding.

         indices(coll):
           for i in indices(coll): body
           → for i in 0..length(coll): body

         enumerate(coll):
           for pair in enumerate(coll): body
           → for __idx in 0..length(coll):
               let pair = (__idx, coll[__idx]) in body

         windows(coll, k):
           for w in windows(coll, k): body
           → for __idx in 0..(length(coll) - k + 1):
               let w = coll[__idx..__idx+k] in body

         enumerate2(m):  (matrix with known col dim)
           for triple in enumerate2(m): body
           → for __i in 0..length(m):
               for __j in 0..<cols>:
                 let triple = (__i, __j, m[__i, __j]) in body
      *)
      match typed_expr_desc iter with
      | TA.ELoopView
          { loop_view_kind = LoopIndices; loop_view_source = coll; _ } ->
          lower_for_indices ~loc ~ty var coll body
      | TA.ELoopView
          { loop_view_kind = LoopEnumerate; loop_view_source = coll; _ } ->
          lower_for_enumerate ~loc ~ty ~destructure_names:None var coll body
      | TA.ELoopView
          {
            loop_view_kind = LoopWindows _;
            loop_view_source = coll;
            loop_view_size_arg = Some size_arg;
            _;
          } ->
          lower_for_windows ~loc ~ty var coll size_arg body
      | TA.ELoopView
          { loop_view_kind = LoopEnumerate2; loop_view_source = m; _ } ->
          lower_for_enumerate2 ~loc ~ty ~destructure_names:None var m body
      | _ -> (
          let iter_ty = type_of_child_expr iter in
          match resource_source_parts iter_ty with
          | Some (resource_ty, _error_ty) ->
              let item_name = fresh_resource_name () in
              let item_var = Core.Var.named item_name in
              let scoped_name =
                if is_wildcard_name var then fresh_resource_name () else var
              in
              let scoped_var = Core.Var.named scoped_name in
              let acquire =
                {
                  Core.desc = CVar item_var;
                  ty = resource_ty;
                  loc = TA.loc iter;
                }
              in
              let body_scope =
                {
                  Core.desc =
                    CResourceScope
                      {
                        rs_var = scoped_var;
                        rs_ty = resource_ty;
                        rs_acquire = acquire;
                        rs_body = lower_child_expr body;
                        rs_cleanup =
                          resource_cleanup_call ~loc resource_ty scoped_var;
                      };
                  ty = TyNamed ("Void", []);
                  loc;
                }
              in
              mk
                (CFor
                   ( loop_binder_for item_name resource_ty,
                     lower_child_expr iter,
                     body_scope ))
          | None ->
              let loop_ty = elem_type_of_iterable ~loc:(TA.loc iter) iter_ty in
              mk
                (CFor
                   ( loop_binder_for var loop_ty,
                     lower_child_expr iter,
                     lower_child_expr body ))))
  | TA.EForTuple (names, iter, body) -> (
      match typed_expr_desc iter with
      | TA.ELoopView
          { loop_view_kind = LoopEnumerate; loop_view_source = coll; _ } ->
          let tmp = fresh_loop_tuple_name () in
          lower_for_enumerate ~loc ~ty ~destructure_names:(Some names) tmp coll
            body
      | TA.ELoopView
          { loop_view_kind = LoopEnumerate2; loop_view_source = m; _ } ->
          let tmp = fresh_loop_tuple_name () in
          lower_for_enumerate2 ~loc ~ty ~destructure_names:(Some names) tmp m
            body
      | _ ->
          let iter_ty = type_of_child_expr iter in
          let tuple_ty =
            match iter_ty with
            | TyNamed ("Dict", [ key_ty; val_ty ]) -> TyTuple [ key_ty; val_ty ]
            | _ -> elem_type_of_iterable ~loc:(TA.loc iter) iter_ty
          in
          let tmp = fresh_loop_tuple_name () in
          let iter_core = lower_child_expr iter in
          let body_core =
            lower_tuple_destruct_with_body ~loc names
              (typed_ident_expr ~loc tmp tuple_ty)
              (lower_child_expr body)
          in
          mk (CFor (loop_binder_for tmp tuple_ty, iter_core, body_core)))
  | TA.ELoopView _ ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "Loop-view producers are internal iterator descriptors. They must be \
           consumed by EFor/EForTuple lowering, not lowered as standalone \
           expressions."
        "loop view reached core lowering outside a for-loop"
  (* === Assignment === *)
  | TA.EAssign (var, rhs) ->
      mk (CAssign (Core.Var.named var, lower_child_expr rhs))
  | TA.ECompoundAssign _ ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "Compound assignment should be desugared during type inference \
           before Core lowering."
        "compound assignment reached core lowering"
  (* === Block: the interesting case === *)
  | TA.EBlock stmts -> lower_block ~loc ~ty stmts
  (* === Stray EVarDecl / ETupleDestruct outside a block ===
     Shouldn't happen in practice but we treat them as singleton blocks
     to avoid surprises. *)
  | TA.EVarDecl _ | TA.ETupleDestruct _ -> lower_block ~loc ~ty [ typed ]
  (* === Data construction === *)
  | TA.ETuple xs -> mk (CTuple (List.map lower_child_expr xs))
  | TA.EList xs ->
      mk
        (CList
           {
             ll_layout = Core_layout_type.list_storage_layout_of_type ty loc;
             ll_elems = List.map lower_child_expr xs;
           })
  | TA.EVector xs -> mk (CVector (List.map lower_child_expr xs))
  | TA.EDict kvs ->
      mk
        (CDict
           (List.map
              (fun (k, v) -> (lower_child_expr k, lower_child_expr v))
              kvs))
  | TA.ERecord fs ->
      mk (CRecord (List.map (fun (n, v) -> (n, lower_child_expr v)) fs))
  | TA.ERecordUpdate (base, fs) ->
      mk
        (CRecordUpdate
           ( lower_child_expr base,
             List.map (fun (n, v) -> (n, lower_child_expr v)) fs ))
  | TA.ERange (lo, hi) -> mk (CRange (lower_child_expr lo, lower_child_expr hi))
  (* === Lambda === *)
  | TA.ELambda typed_func ->
      let func = TA.func_ast typed_func in
      let params =
        List.map
          (fun p ->
            let name = match p.param_name with Some n -> n | None -> "_" in
            let pty =
              match p.param_type with
              | Some t ->
                  require_final_type ~loc:p.param_loc
                    ~context:"lambda parameter type" t
              | None ->
                  Core_error.errorf (Core_error.Stage Core_stage.Lower)
                    p.param_loc
                    ~hint:
                      "lambda parameters must be typed before lowering; this \
                       usually means inference accepted a lambda without \
                       assigning its parameter type."
                    "lambda param missing type"
            in
            (Core.Var.named name, pty))
          func.func_params
      in
      let body =
        match TA.func_body_expr typed_func with
        | Ok (Some b) -> lower_child_expr b
        | Ok None ->
            Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
              ~hint:
                "parser/typecheck should not emit a lambda without a body; \
                 reject or repair the AST before Core lowering."
              "lambda has no body"
        | Error err -> typed_ast_error err
      in
      let return_ty =
        require_final_type ~loc ~context:"lambda semantic return type"
          (TA.func_semantic_return_type typed_func)
      in
      let lam =
        {
          Core.lam_params = params;
          lam_body = body;
          lam_return_ty = return_ty;
          lam_is_pure = func.func_is_pure;
        }
      in
      mk (CLambda lam)
  (* === String interpolation (preserved as Core sugar node) === *)
  | TA.EStringInterp (parts, is_multiline) ->
      let parts' =
        List.map
          (function
            | TA.InterpLit s -> Core.IPLit s
            | TA.InterpExpr e -> Core.IPExpr (lower_child_expr e))
          parts
      in
      mk (CStringInterp (parts', is_multiline))
  | TA.EStringInterpRaw _ ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "run string interpolation lowering before typechecking and Core \
           lowering so raw interpolation is parsed into EStringInterp parts."
        "EStringInterpRaw reached lowering"
  | TA.EQuestionBind _ ->
      (* A stray [EQuestionBind] outside [lower_block]'s continuation-aware path
         is a typechecker error; if one reaches lowering directly, raise a
         structured error. *)
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "'name ?= expr' must be used as a statement before the expression \
           that returns Option or Result"
        "EQuestionBind reached lowering outside a result-producing block"
  | TA.EWith (binding, body) -> lower_with ~loc ~ty binding body
  | TA.EDebugBlock body ->
      let debug_ty = Ast.TyNamed ("Void", []) in
      let body = lower_block ~loc ~ty:debug_ty body in
      mk (CDebugBlock body)
  | TA.ESelect arms ->
      let lower_arm (arm : TA.select_arm) =
        let select_arm_kind =
          match arm.select_arm_kind with
          | TA.SelectRecv { select_bind; select_elem_ty; select_channel } ->
              Core.SelectRecv
                {
                  select_bind = Core.Var.named select_bind;
                  select_elem_ty;
                  select_channel = lower_child_expr select_channel;
                }
          | TA.SelectAfter timeout ->
              Core.SelectAfter (lower_timeout_expr timeout)
          | TA.SelectSealed { select_channel = channel; _ } ->
              Core.SelectSealed (lower_child_expr channel)
        in
        {
          Core.select_arm_kind;
          select_arm_body = lower_child_expr arm.select_arm_body;
          select_arm_loc = arm.select_arm_loc;
        }
      in
      mk (CSelect { select_arms = List.map lower_arm arms })
  (* === Concurrency === *)
  | TA.EConcurrent (body, timeout, max_threads) ->
      (* Standalone concurrent expression (no enclosing block to supply a
         tail). Extract the task bindings; use [CVoid] as the tail since
         there's nothing after. Note that [lower_block] handles the
         common case where [EConcurrent] appears at a block head — there,
         the subsequent block statements become the tail, scoping the
         concurrent bindings over them correctly. *)
      let bindings = lower_concurrent_bindings body in
      let void_tail =
        { Core.desc = CVoid; ty = Ast.TyNamed ("Void", []); loc }
      in
      mk
        (CConcurrent
           {
             conc_bindings = bindings;
             conc_body = void_tail;
             conc_timeout = Option.map lower_timeout_expr timeout;
             conc_max_threads = max_threads;
           })
  | TA.EConcurrentBind _ ->
      (* A stray [EConcurrentBind] outside a concurrent block / block head
         is a type error in the source, but tolerate it by lowering as a
         singleton block. *)
      lower_block ~loc ~ty [ typed ]
  | TA.EConcurrentlyLoop (var, iter, body, timeout, width) ->
      let output =
        if Types.types_equal ty (TyNamed ("Void", [])) then
          Core.ConcurrentlyLoopDiscard
        else Core.ConcurrentlyLoopCollect
      in
      lower_concurrently_loop ~loc ~ty ~output var iter body timeout width
  | TA.EDetach inner ->
      mk (CDetach { detach_body = lower_child_expr inner; detach_task = None })
  (* Subscript forms should never reach core_lower:
     - ESubscript / ESubscriptMulti are rewritten to calls by
       the Blorp typecheck-source finalizer before typecheck.
     - ESubscriptAssign is rewritten to an explicit call by infer.ml
       during type-checking (the mutability-checked [ESubscriptAssign]
       handler produces a typed [ECall] node). *)
  | TA.ESubscript _ | TA.ESubscriptMulti _ | TA.ESubscriptAssign _ ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "The Blorp typecheck-source finalizer (ESubscript/ESubscriptMulti) \
           or infer.ml's ESubscriptAssign handler should have rewritten this \
           to a checked_get/checked_set call before lowering."
        "subscript node survived to core_lower"
  | TA.EFuncDecl _ ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "nested function declarations are eliminated by the nested-hoist \
           pre-infer pass; if this fires, the pass didn't run or missed a \
           nesting site"
        "EFuncDecl survived to core_lower"

and lower_child_expr (e : TA.expr) : Core.core = lower_typed_expr_core e

and lower_timeout_expr (e : TA.expr) : Core.core =
  let lowered = lower_child_expr e in
  if Types.types_equal lowered.ty ty_int then lowered
  else if
    match lowered.ty with Ast.TyConstInt _ -> true | _ -> false
  then { lowered with ty = ty_int }
  else if Types.is_std_duration_type lowered.ty then
    lower_duration_timeout_milliseconds lowered
  else
    Core_error.errorf (Core_error.Stage Core_stage.Lower) lowered.loc
      ~hint:
        "Inference should accept only Int milliseconds or std/units.Duration \
         for structured concurrency timeouts."
      "invalid concurrency timeout type reached Core lowering: %s"
      (Types.type_to_string lowered.ty)

and lower_concurrently_loop ~loc ~ty ~output var iter body timeout width =
  let parent_scope = current_task_scope_id () in
  let child_scope = fresh_task_scope_id () in
  let task_scope =
    Core.concurrent_task_scope ~parent:parent_scope ~child:child_scope
  in
  let width =
    match width with
    | Ast.ConcurrentlyLoopLimit n ->
        Core.ConcurrentlyLoopLimit (Core.Build.lit_int ~loc n)
  in
  let iter_ty = type_of_child_expr iter in
  let cf_var, cf_item_mode, body_core =
    match resource_source_parts iter_ty with
    | Some (resource_ty, error_ty) ->
        let item_name = fresh_resource_name () in
        let item_var = Core.Var.named item_name in
        let scoped_name =
          if is_wildcard_name var then fresh_resource_name () else var
        in
        let scoped_var = Core.Var.named scoped_name in
        let acquire =
          { Core.desc = CVar item_var; ty = resource_ty; loc = TA.loc iter }
        in
        let user_body =
          with_current_task_scope child_scope (fun () -> lower_child_expr body)
        in
        let body_core =
          {
            Core.desc =
              CResourceScope
                {
                  rs_var = scoped_var;
                  rs_ty = resource_ty;
                  rs_acquire = acquire;
                  rs_body = user_body;
                  rs_cleanup = resource_cleanup_call ~loc resource_ty scoped_var;
                };
            ty = TyNamed ("Void", []);
            loc;
          }
        in
        ( item_var,
          Core.ConcurrentlyLoopMoveResourceItem
            { clmi_resource_ty = resource_ty; clmi_error_ty = error_ty },
          body_core )
    | None ->
        ( Core.Var.named var,
          Core.ConcurrentlyLoopCopyItem,
          with_current_task_scope child_scope (fun () -> lower_child_expr body)
        )
  in
  let body_core =
    match output with
    | Core.ConcurrentlyLoopCollect -> body_core
    | Core.ConcurrentlyLoopDiscard ->
        let ty_void = TyNamed ("Void", []) in
        if Types.types_equal body_core.ty ty_void then body_core
        else
          {
            Core.desc =
              CSeq (body_core, { Core.desc = CVoid; ty = ty_void; loc });
            ty = ty_void;
            loc;
          }
  in
  {
    Core.desc =
      CConcurrentlyLoop
        {
          cf_var;
          cf_iter = lower_child_expr iter;
          cf_body = body_core;
          cf_timeout = Option.map lower_timeout_expr timeout;
          cf_width = width;
          cf_output = output;
          cf_item_mode;
          cf_task_scope = task_scope;
          cf_task = None;
        };
    ty;
    loc;
  }

and typed_with_type (init : TA.expr) (expected : Ast.type_expr) : TA.expr =
  let info = TA.type_info init in
  typed_expr_with_type ~context:"annotated binding lowering"
    ?source_ty:(TA.type_info_source_type info)
    ~origin:(TA.type_info_origin info)
    ?resolved_call:(TA.expr_resolved_call init)
    ~proofs:(TA.type_info_proofs info) (TA.ast init) expected

and lower_binding_init (ty_ann : Ast.type_expr option) (init : TA.expr) :
    Core.core =
  match ty_ann with
  | None -> lower_child_expr init
  | Some expected ->
      (* Typecheck/inference already accepted annotated bindings. Lowering
         treats the annotation as the contextual result type so later layout
         decisions do not accidentally preserve narrower literal-shaped types
         like Option[#42] for a binding declared as Option[Int]. *)
      lower_child_expr (typed_with_type init expected)

and lower_ast_binding_init (ty_ann : Ast.type_expr option) (init : Ast.expr) :
    Core.core =
  lower_binding_init ty_ann (require_typed_expr init)

(** Lower a block to a nested [CLet]/[CSeq] chain.

    The input [stmts] is the block's statement list (in source order).
    The result has type [ty] (the block's overall type).

    Rules:
    - Empty block → [CVoid].
    - Single expression → just lower it (no wrapping).
    - [EVarDecl] at head → [CLet] scoping over the rest of the block.
    - [ETupleDestruct] at head → nested [CLet]s (temp + field bindings).
    - Any other expression at head → [CSeq] with rest as the second arg.
    - The last element is the block's result (type [ty]).
*)

(** Extract a source function name from a call's callee AST.
    - [EIdent name] → [Some name]
    - [EFieldAccess (_, name)] → [Some name]  (module-qualified or UFCS)
    - Anything else (lambda, indirect call, etc.) → [None]. *)
and callee_source_name (e : TA.expr) : string option =
  match typed_expr_desc e with
  | TA.EIdent n -> Some n
  | TA.EFieldAccess (_, n) -> Some n
  | _ -> None

(** Phase 4.2 entry point: if [callee(arg)] is an element-wise lift over
    an array arg, emit the specialized per-type runtime call
    directly. [result_ty] is the outer call's expected type (the tensor-
    valued return inference produced when it recognized the lift). *)
and try_elementwise_lift (result_ty : Ast.type_expr) (callee : TA.expr)
    (args : TA.expr list) : Core.core option =
  match args with
  | [ arg ] -> (
      let name_opt = callee_source_name callee in
      let arg_ty = type_of_child_expr arg in
      let is_tensor_ty t = Types.is_array_type t in
      let is_tensor = is_tensor_ty arg_ty in
      let result_is_tensor = is_tensor_ty result_ty in
      (* Distinguishing an inference-lifted call (where we should rewrite) from a
         user function that happens to share a name (where we must NOT steal the
         call): inference only lifts scalar scalar-returning callees. When
         inference applied the lift, [type_of_child_expr callee] is [TyFunc { return =
         scalar; ... }] even though the outer call's [expr_type] is tensor. A
         user function already typed [(T[...]) -> T[...]] has a
         tensor-returning callee type — no lift occurred, and intercepting here
         would silently discard the user's implementation.

         The wider generalization (any pure scalar user function auto-lifts) is
         deferred to a future [tensor_map] intrinsic. *)
      let callee_returns_scalar =
        match type_of_child_expr callee with
        | Ast.TyFunc { return; _ } -> not (is_tensor_ty return)
        | _ -> false
      in
      match name_opt with
      | Some name
        when is_tensor && result_is_tensor && callee_returns_scalar
             && List.mem name Codegen_builtins.elementwise_tensor_functions ->
          let elem_ty =
            match Types.array_parts arg_ty with
            | Some (elem, _) -> elem
            | None -> Ast.TyNamed ("Float", [])
          in
          let suffix =
            match elem_ty with
            | Ast.TyNamed ("Float32", _) -> "_float32"
            | Ast.TyNamed ("Float16", _) -> "_float16"
            | _ -> ""
          in
          let c_name = "blorp_vector_" ^ name ^ suffix in
          let loc = TA.loc callee in
          let dummy =
            { Core.desc = CVoid; ty = Ast.TyNamed ("Void", []); loc }
          in
          let arg_core = lower_child_expr arg in
          Some
            {
              Core.desc = CCall (CKBuiltin c_name, dummy, [ arg_core ]);
              ty = result_ty;
              loc;
            }
      | _ -> None)
  | _ -> None

and lower_block ~loc ~ty (stmts : TA.expr list) : Core.core =
  let mk d = { Core.desc = d; ty; loc } in
  match stmts with
  | [] -> mk CVoid
  | first :: rest -> (
      match typed_expr_desc first with
      | TA.EVarDecl (name, ty_ann, init, is_mut) ->
          (* [EVarDecl] scopes over the rest of the block, even if [rest] is
             empty — in which case the body is [CVoid]. Previously this case
             short-circuited for singleton blocks and infinite-looped. *)
          let init' = lower_binding_init ty_ann init in
          let bind_ty =
            match ty_ann with
            | Some t ->
                require_final_type ~loc:(TA.loc first)
                  ~context:"local binding annotation" t
            | None -> init'.ty
          in
          let body = lower_block ~loc:(TA.loc first) ~ty rest in
          let bind =
            {
              Core.bind_var = Core.Var.named name;
              bind_mut = is_mut;
              bind_ty;
              bind_rhs = init';
            }
          in
          mk (CLet (bind, body))
      | TA.ETupleDestruct (names, value) ->
          lower_tuple_destruct ~loc ~ty names value rest
      | TA.EConcurrent (conc_stmts, timeout, max_threads) ->
          (* Concurrent block at block head: extract task bindings into the
             [CConcurrent] node's [conc_bindings] field, with subsequent
             block statements becoming [conc_body] (the tail). This shape
             lets downstream passes (the Blorp Perceus pass especially) see the
             concurrent bindings as scoping over their real uses in the
             tail, rather than being trapped inside an opaque [CConcurrent]
             body where their uses look like zero. *)
          let bindings = lower_concurrent_bindings conc_stmts in
          let tail = lower_block ~loc:(TA.loc first) ~ty rest in
          mk
            (CConcurrent
               {
                 conc_bindings = bindings;
                 conc_body = tail;
                 conc_timeout = Option.map lower_timeout_expr timeout;
                 conc_max_threads = max_threads;
               })
      | TA.EConcurrentBind _ ->
          (* Stray [EConcurrentBind] outside an enclosing [EConcurrent].
             The typechecker should reject these; if one reaches lowering,
             fail loudly rather than silently producing an ill-formed
             [CLet] that no later pass knows how to handle. *)
          Core_error.errorf (Core_error.Stage Core_stage.Lower) (TA.loc first)
            ~hint:
              "concurrent bindings (name = expr) must appear inside a \
               concurrent: block"
            "EConcurrentBind reached lowering outside an EConcurrent"
      | TA.EQuestionBind _ ->
          if rest = [] then
            Core_error.errorf (Core_error.Stage Core_stage.Lower) (TA.loc first)
              ~hint:
                "the typechecker should reject a final ?= binding before Core \
                 lowering"
              "EQuestionBind reached lowering without a success continuation"
          else lower_question_bind ~block_ty:ty first rest
      | TA.EConcurrentlyLoop (var, iter, body, timeout, width) when rest <> []
        ->
          let ty_void = TyNamed ("Void", []) in
          let first' =
            lower_concurrently_loop ~loc:(TA.loc first) ~ty:ty_void
              ~output:Core.ConcurrentlyLoopDiscard var iter body timeout width
          in
          let rest' = lower_block ~loc:(TA.loc first) ~ty rest in
          mk (CSeq (first', rest'))
      | _ when rest = [] ->
          (* Non-binding singleton: just lower as the block's result. *)
          lower_child_expr first
      | _ ->
          let first' = lower_child_expr first in
          let rest' = lower_block ~loc:(TA.loc first) ~ty rest in
          mk (CSeq (first', rest')))

(** Lower a direct [?=] block statement.

    This is deliberately continuation-shaped instead of a non-local return:
    the success arm evaluates the rest of the enclosing block, while the
    failure arm produces the block's Option/Result value. That preserves the
    normal expression tree so Perceus can place retains/drops structurally.
    Inference currently rejects loop bodies because a loop would need a real
    early-return node plus scope cleanup. *)
and lower_question_bind ~block_ty (stmt : TA.expr) (rest : TA.expr list) :
    Core.core =
  match typed_expr_desc stmt with
  | TA.EQuestionBind (name, ty_ann, rhs) ->
      let block_kind =
        require_carrier_kind ~loc:(TA.loc stmt)
          ~hint:
            "typechecking should only allow ?= in blocks returning Option or \
             Result"
          ~what:"?= block" block_ty
      in
      let rhs' = lower_child_expr rhs in
      let node_kind =
        require_carrier_kind ~loc:(TA.loc rhs)
          ~hint:"'name ?= expr' requires expr to be Option[T] or Result[T, E]"
          ~what:"?= rhs" rhs'.ty
      in
      if node_kind <> block_kind then
        Core_error.errorf (Core_error.Stage Core_stage.Lower) (TA.loc stmt)
          ~hint:
            "typechecking should reject mixed Option/Result ?= carriers before \
             Core lowering"
          "?= carrier kind changed between inference and lowering";
      let _ =
        match ty_ann with
        | Some t ->
            require_final_type ~loc:(TA.loc stmt)
              ~context:"?= binding annotation" t
        | None ->
            require_carrier_success_type ~loc:(TA.loc rhs)
              ~hint:
                "'name ?= expr' requires expr to be Option[T] or Result[T, E]"
              ~what:"?= rhs" rhs'.ty
      in
      let tmp_name = fresh_question_bind_name () in
      let tmp = Core.Var.named tmp_name in
      let tmp_ref = { Core.desc = CVar tmp; ty = rhs'.ty; loc = TA.loc stmt } in
      let success_body = lower_block ~loc:(TA.loc stmt) ~ty:block_ty rest in
      let failure_name = fresh_question_bind_name () in
      let failure_ty =
        match node_kind with
        | CarrierOption -> Ast.TyNamed ("Void", [])
        | CarrierResult ->
            require_carrier_failure_type ~loc:(TA.loc rhs)
              ~hint:
                "'name ?= expr' requires expr to be Option[T] or Result[T, E]"
              ~what:"?= rhs" rhs'.ty
      in
      let fallback_body =
        carrier_failure_expr ~loc:(TA.loc stmt) ~kind:node_kind
          ~carrier_ty:block_ty ~failure_name ~failure_ty
      in
      let arms =
        [
          ( Ast.PatConstructor
              (carrier_success_ctor node_kind, [ Ast.PatVar name ]),
            success_body );
          (carrier_failure_pattern node_kind failure_name, fallback_body);
        ]
      in
      let match_expr =
        {
          Core.desc = CMatchArms (tmp_ref, arms);
          ty = block_ty;
          loc = TA.loc stmt;
        }
      in
      let binding =
        {
          Core.bind_var = tmp;
          bind_mut = false;
          bind_ty = rhs'.ty;
          bind_rhs = rhs';
        }
      in
      {
        Core.desc = CLet (binding, match_expr);
        ty = block_ty;
        loc = TA.loc stmt;
      }
  | _ ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) (TA.loc stmt)
        "lower_question_bind called on non-EQuestionBind"

and lower_with ~(loc : Ast.loc) ~(ty : Ast.type_expr)
    (binding : TA.with_binding) (body : TA.expr) : Core.core =
  let resource_ty =
    match binding.with_type with
    | Some t ->
        require_final_type
          ~loc:(TA.loc binding.with_value)
          ~context:"with resource binding annotation" t
    | None -> (
        match binding.with_kind with
        | WithPlain -> TA.semantic_type binding.with_value
        | WithTry ->
            let value_ty = TA.semantic_type binding.with_value in
            let _ =
              require_carrier_kind
                ~loc:(TA.loc binding.with_value)
                ~hint:
                  "typechecking should only allow with ?= on Option or Result \
                   acquisitions"
                ~what:"with ?= acquisition" value_ty
            in
            require_carrier_success_type
              ~loc:(TA.loc binding.with_value)
              ~hint:
                "typechecking should only allow with ?= on Option or Result \
                 acquisitions"
              ~what:"with ?= acquisition" value_ty)
  in
  let scoped_name =
    if is_wildcard_name binding.with_name then fresh_resource_name ()
    else binding.with_name
  in
  let scoped_var = Core.Var.named scoped_name in
  let resource_scope acquire =
    let body' = lower_child_expr body in
    {
      Core.desc =
        CResourceScope
          {
            rs_var = scoped_var;
            rs_ty = resource_ty;
            rs_acquire = acquire;
            rs_body = body';
            rs_cleanup = resource_cleanup_call ~loc resource_ty scoped_var;
          };
      ty;
      loc;
    }
  in
  match binding.with_kind with
  | WithPlain ->
      let acquire = lower_child_expr binding.with_value in
      resource_scope acquire
  | WithTry ->
      let rhs = lower_child_expr binding.with_value in
      let node_kind =
        require_carrier_kind
          ~loc:(TA.loc binding.with_value)
          ~hint:
            "typechecking should only allow with ?= on Option or Result \
             acquisitions"
          ~what:"with ?= acquisition" rhs.ty
      in
      let block_kind =
        require_carrier_kind ~loc
          ~hint:
            "typechecking should only allow with ?= in blocks returning Option \
             or Result"
          ~what:"with ?= result" ty
      in
      if node_kind <> block_kind then
        Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
          ~hint:
            "typechecking should reject mixed Option/Result with ?= carriers \
             before Core lowering"
          "with ?= carrier kind changed between inference and lowering";
      let tmp_name = fresh_question_bind_name () in
      let tmp = Core.Var.named tmp_name in
      let tmp_ref = { Core.desc = CVar tmp; ty = rhs.ty; loc } in
      let payload_name = fresh_resource_name () in
      let payload =
        {
          Core.desc = CVar (Core.Var.named payload_name);
          ty = resource_ty;
          loc;
        }
      in
      let success_body = resource_scope payload in
      let failure_name =
        match binding.with_error_map with
        | Some mapper when not (is_wildcard_name mapper.with_error_name) ->
            mapper.with_error_name
        | _ -> fresh_question_bind_name ()
      in
      let failure_ty =
        match node_kind with
        | CarrierOption -> Ast.TyNamed ("Void", [])
        | CarrierResult ->
            require_carrier_failure_type
              ~loc:(TA.loc binding.with_value)
              ~hint:
                "typechecking should only allow with ?= on Option or Result \
                 acquisitions"
              ~what:"with ?= acquisition" rhs.ty
      in
      let fallback_body =
        match binding.with_error_map with
        | None ->
            carrier_failure_expr ~loc ~kind:node_kind ~carrier_ty:ty
              ~failure_name ~failure_ty
        | Some mapper -> (
            match node_kind with
            | CarrierOption ->
                Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
                  ~hint:
                    "typechecking should only allow with ?= error mapping on \
                     Result acquisitions"
                  "with ?= error mapping reached lowering for Option"
            | CarrierResult ->
                let mapped_error = lower_child_expr mapper.with_error_value in
                builtin_call ~loc "blorp_result_err" [ mapped_error ] ty)
      in
      let arms =
        [
          ( Ast.PatConstructor
              (carrier_success_ctor node_kind, [ Ast.PatVar payload_name ]),
            success_body );
          (carrier_failure_pattern node_kind failure_name, fallback_body);
        ]
      in
      let match_expr = { Core.desc = CMatchArms (tmp_ref, arms); ty; loc } in
      {
        Core.desc =
          CLet
            ( {
                bind_var = tmp;
                bind_mut = false;
                bind_ty = rhs.ty;
                bind_rhs = rhs;
              },
              match_expr );
        ty;
        loc;
      }

(** Rewrite [for i in indices(coll): body] into an index-based loop.

    Produces:
      for i in 0..length(coll):
        body
*)
and lower_for_indices ~loc ~ty (var : string) (coll : TA.expr) (body : TA.expr)
    : Core.core =
  let coll_core = lower_child_expr coll in
  let coll_ty = coll_core.ty in
  let idx_ty = indices_elem_type ~loc coll_ty in
  let int_ty = TyNamed ("Int", []) in
  let zero = { Core.desc = CLit (LitInt 0L); ty = int_ty; loc } in
  let length_callee =
    {
      Core.desc = CVar (Core.Var.named "length");
      ty = TyFunc { params = [ coll_ty ]; return = int_ty; is_pure = true };
      loc;
    }
  in
  let length_call =
    {
      Core.desc = CCall (CKUnknown, length_callee, [ coll_core ]);
      ty = int_ty;
      loc;
    }
  in
  let range = { Core.desc = CRange (zero, length_call); ty = int_ty; loc } in
  {
    Core.desc = CFor (loop_binder_for var idx_ty, range, lower_child_expr body);
    ty;
    loc;
  }

(** Rewrite [for x in enumerate(coll): body] into an index-based loop.

    Produces:
      for __idx in 0..length(coll):
        let x = (__idx, coll[__idx]) in body

    [iter_elem_ty] is the tuple [(idx_ty, elem_ty)] that inference assigned
    to the iterator; we split it to type the synthesized tuple.
*)
and lower_for_enumerate ~loc ~ty ~destructure_names (var : string)
    (coll : TA.expr) (body : TA.expr) : Core.core =
  let coll_core = lower_child_expr coll in
  let coll_ty = coll_core.ty in
  let idx_ty, elem_ty = enumerate_elem_type ~loc coll_ty in
  let int_ty = TyNamed ("Int", []) in
  let forbidden = var :: Option.value destructure_names ~default:[] in
  let idx_name = fresh_loop_internal_name "__idx" forbidden in
  let idx_v = Core.Var.named idx_name in
  let idx_ref = { Core.desc = CVar idx_v; ty = idx_ty; loc } in
  let zero = { Core.desc = CLit (LitInt 0L); ty = int_ty; loc } in
  let length_callee =
    {
      Core.desc = CVar (Core.Var.named "length");
      ty = TyFunc { params = [ coll_ty ]; return = int_ty; is_pure = true };
      loc;
    }
  in
  let length_call =
    {
      Core.desc = CCall (CKUnknown, length_callee, [ coll_core ]);
      ty = int_ty;
      loc;
    }
  in
  let range = { Core.desc = CRange (zero, length_call); ty = int_ty; loc } in
  (* Element-per-iteration expression:
     - 1D array [T[#N]] -> checked_get(coll, idx) : T
     - 2D+ array [T[#M, #Ds...]] -> blorp_tensor_slice_row(coll, idx,
       row_size, first_inner_dim) : T[#Ds...]. This mirrors the
       peeling that emit_for_tensor_peel does for bare [for row in m:]
       so [for (i, row) in enumerate(m):] produces the same row sub-tensor. *)
  let inner_dims =
    match Types.array_parts coll_ty with Some (_, _ :: rest) -> rest | _ -> []
  in
  let elem_expr =
    if inner_dims = [] then
      (* 1D: checked_get. *)
      let get_callee =
        {
          Core.desc = CVar (Core.Var.named "checked_get");
          ty =
            TyFunc
              { params = [ coll_ty; int_ty ]; return = elem_ty; is_pure = true };
          loc;
        }
      in
      {
        Core.desc = CCall (CKUnknown, get_callee, [ coll_core; idx_ref ]);
        ty = elem_ty;
        loc;
      }
    else
      (* 2D+: tensor_slice_row. Requires all inner dims to be compile-time
         constants for Phase 4.1's row_size / first_inner_dim literals.
         Generic-dim codepaths are Phase 4.4. *)
      let row_size, first_inner =
        let all_const =
          List.for_all
            (function Ast.TyConstInt _ -> true | _ -> false)
            inner_dims
        in
        if all_const then
          let prod =
            List.fold_left
              (fun acc ty ->
                match ty with Ast.TyConstInt n -> acc * n | _ -> acc)
              1 inner_dims
          in
          let first =
            match inner_dims with Ast.TyConstInt n :: _ -> n | _ -> 1
          in
          (prod, first)
        else (0, 0)
      in
      if row_size = 0 then
        Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
          ~hint:
            "enumerate over multidimensional tensors currently needs concrete \
             inner dimensions so Core lowering can materialize row-size \
             literals. Monomorphize dimensions before lowering or avoid \
             enumerate on tensors with generic inner dimensions."
          "enumerate over a 2D+ tensor with non-literal inner dims"
      else
        let mk_int n =
          { Core.desc = CLit (LitInt (Int64.of_int n)); ty = int_ty; loc }
        in
        let dummy_callee =
          { Core.desc = CVoid; ty = TyNamed ("Void", []); loc }
        in
        {
          Core.desc =
            CCall
              ( CKBuiltin "blorp_tensor_slice_row",
                dummy_callee,
                [ coll_core; idx_ref; mk_int row_size; mk_int first_inner ] );
          ty = elem_ty;
          loc;
        }
  in
  let body' = lower_child_expr body in
  let loop_body =
    match destructure_names with
    | Some [ idx_name; elem_name ] ->
        bind_loop_view_fields ~loc
          [ (idx_name, idx_ty, idx_ref); (elem_name, elem_ty, elem_expr) ]
          body'
    | Some names ->
        Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
          ~hint:"enumerate yields exactly two values: the index and the element"
          "enumerate tuple loop has %d binders, expected 2" (List.length names)
    | None ->
        let tup_ty = TyTuple [ idx_ty; elem_ty ] in
        let tuple =
          { Core.desc = CTuple [ idx_ref; elem_expr ]; ty = tup_ty; loc }
        in
        let bind =
          {
            Core.bind_var = Core.Var.named var;
            bind_mut = false;
            bind_ty = tup_ty;
            bind_rhs = tuple;
          }
        in
        { Core.desc = CLet (bind, body'); ty = body'.ty; loc }
  in
  {
    Core.desc = CFor (loop_binder_for idx_name idx_ty, range, loop_body);
    ty;
    loc;
  }

(** Rewrite [for w in windows(coll, k): body] into an index-based loop.

    Produces:
      for __idx in 0..(length(coll) - k + 1):
        let w = coll[__idx .. __idx + k] in body

    The slice is a T[#k] that aliases into coll (zero-copy after
    eventual view work; for now the slice builtin materializes).
*)
and lower_for_windows ~loc ~ty (var : string) (coll : TA.expr)
    (size_arg : TA.expr) (body : TA.expr) : Core.core =
  let coll_core = lower_child_expr coll in
  let coll_ty = coll_core.ty in
  let elem_ty =
    match Types.array_parts coll_ty with
    | Some (e, _) -> e
    | None ->
        Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
          ~hint:
            "windows lowers to tensor slicing and therefore requires an \
             array/tensor input. The typechecker should reject any other \
             collection before lowering."
          "windows requires an array, got %s"
          (Types.type_to_string coll_ty)
  in
  let k =
    match typed_expr_desc size_arg with
    | TA.ELiteral (LitInt n) -> n
    | _ ->
        Core_error.errorf (Core_error.Stage Core_stage.Lower) (TA.loc size_arg)
          ~hint:
            "windows currently lowers to an index loop with a statically sized \
             slice; pass an integer literal for the window size."
          "windows size must be a compile-time integer literal"
  in
  let int_ty = TyNamed ("Int", []) in
  let window_ty = Types.ty_array elem_ty [ TyConstInt (Int64.to_int k) ] in
  let idx_v = Core.Var.named "__idx" in
  let idx_ref = { Core.desc = CVar idx_v; ty = int_ty; loc } in
  let zero = { Core.desc = CLit (LitInt 0L); ty = int_ty; loc } in
  let length_callee =
    {
      Core.desc = CVar (Core.Var.named "length");
      ty = TyFunc { params = [ coll_ty ]; return = int_ty; is_pure = true };
      loc;
    }
  in
  let length_call =
    {
      Core.desc = CCall (CKUnknown, length_callee, [ coll_core ]);
      ty = int_ty;
      loc;
    }
  in
  (* end = length(coll) - k + 1 *)
  let k_lit = { Core.desc = CLit (LitInt k); ty = int_ty; loc } in
  let one = { Core.desc = CLit (LitInt 1L); ty = int_ty; loc } in
  let minus_k =
    { Core.desc = CBin (Ast.Sub, length_call, k_lit); ty = int_ty; loc }
  in
  let end_expr =
    { Core.desc = CBin (Ast.Add, minus_k, one); ty = int_ty; loc }
  in
  let range = { Core.desc = CRange (zero, end_expr); ty = int_ty; loc } in
  (* idx + k *)
  let idx_plus_k =
    { Core.desc = CBin (Ast.Add, idx_ref, k_lit); ty = int_ty; loc }
  in
  (* checked_slice(coll, idx, idx + k) -> Option[T[#k]]; for the in-bounds
     case we just access .Some. Safer path: emit a dedicated vector_window
     intrinsic. For now, emit checked_slice + unwrap. *)
  let slice_callee =
    {
      Core.desc = CVar (Core.Var.named "checked_slice");
      ty =
        TyFunc
          {
            params = [ coll_ty; int_ty; int_ty ];
            return = window_ty;
            is_pure = true;
          };
      loc;
    }
  in
  let slice_call =
    {
      Core.desc =
        CCall (CKUnknown, slice_callee, [ coll_core; idx_ref; idx_plus_k ]);
      ty = window_ty;
      loc;
    }
  in
  let bind =
    {
      Core.bind_var = Core.Var.named var;
      bind_mut = false;
      bind_ty = window_ty;
      bind_rhs = slice_call;
    }
  in
  let body' = lower_child_expr body in
  let let_node = { Core.desc = CLet (bind, body'); ty = body'.ty; loc } in
  {
    Core.desc = CFor (loop_binder_for "__idx" int_ty, range, let_node);
    ty;
    loc;
  }

(** Rewrite [for x in enumerate2(m): body] into a nested index-based loop.

    Produces:
      for __i in 0..length(m):
        for __j in 0..<cols>:
          let x = (__i, __j, m[__i, __j]) in body

    Concrete-dim matrix [T[#M, #N]] -> [<cols>] is the literal [#N].
    Generic-dim matrix (dim2 is [TyVar] or any non-[TyConstInt]) → [<cols>]
    is the runtime expression [capacity(m) / length(m)]: for a 2D tensor with
    flat storage, [capacity = rows × cols] and [length = rows], so
    [capacity / length = cols]. This mirrors the fallback that multiply uses
    when its dims aren't all literals (`core_specialize.ml:470`). *)
and lower_for_enumerate2 ~loc ~ty ~destructure_names (var : string)
    (m : TA.expr) (body : TA.expr) : Core.core =
  let m_core = lower_child_expr m in
  let m_ty = m_core.ty in
  match Types.array_parts m_ty with
  | Some (elem_ty, dim1 :: dim2 :: _) ->
      let int_ty = TyNamed ("Int", []) in
      let void_ty = TyNamed ("Void", []) in
      let forbidden = var :: Option.value destructure_names ~default:[] in
      let i_name = fresh_loop_internal_name "__i" forbidden in
      let j_name = fresh_loop_internal_name "__j" forbidden in
      let row_idx_ty =
        match dim1 with
        | TyConstInt n when n > 0 -> TyRange (TyConstInt n)
        | TyVar n -> TyRange (TyVar n)
        | _ -> int_ty
      in
      let col_idx_ty =
        match dim2 with
        | TyConstInt n when n > 0 -> TyRange (TyConstInt n)
        | TyVar n -> TyRange (TyVar n)
        | _ -> int_ty
      in
      let i_v = Core.Var.named i_name in
      let j_v = Core.Var.named j_name in
      let i_ref = { Core.desc = CVar i_v; ty = row_idx_ty; loc } in
      let j_ref = { Core.desc = CVar j_v; ty = col_idx_ty; loc } in
      let zero = { Core.desc = CLit (LitInt 0L); ty = int_ty; loc } in
      let length_callee =
        {
          Core.desc = CVar (Core.Var.named "length");
          ty = TyFunc { params = [ m_ty ]; return = int_ty; is_pure = true };
          loc;
        }
      in
      let rows_expr =
        {
          Core.desc = CCall (CKUnknown, length_callee, [ m_core ]);
          ty = int_ty;
          loc;
        }
      in
      (* cols expression: literal when dim2 is compile-time known, runtime
         capacity/len otherwise. *)
      let cols_expr =
        match dim2 with
        | TyConstInt n_cols ->
            {
              Core.desc = CLit (LitInt (Int64.of_int n_cols));
              ty = int_ty;
              loc;
            }
        | _ ->
            let dummy_callee = { Core.desc = CVoid; ty = void_ty; loc } in
            let capacity_call =
              {
                Core.desc =
                  CCall (CKIntrinsic "tensor_capacity", dummy_callee, [ m_core ]);
                ty = int_ty;
                loc;
              }
            in
            {
              Core.desc = CBin (Ast.Div, capacity_call, rows_expr);
              ty = int_ty;
              loc;
            }
      in
      let outer_range =
        { Core.desc = CRange (zero, rows_expr); ty = int_ty; loc }
      in
      let inner_range =
        { Core.desc = CRange (zero, cols_expr); ty = int_ty; loc }
      in
      let get2_callee =
        {
          Core.desc = CVar (Core.Var.named "matrix_checked_get");
          ty =
            TyFunc
              {
                params = [ m_ty; int_ty; int_ty ];
                return = elem_ty;
                is_pure = true;
              };
          loc;
        }
      in
      let get2_call =
        {
          Core.desc = CCall (CKUnknown, get2_callee, [ m_core; i_ref; j_ref ]);
          ty = elem_ty;
          loc;
        }
      in
      let tup_ty = TyTuple [ row_idx_ty; col_idx_ty; elem_ty ] in
      let body' = lower_child_expr body in
      let loop_body =
        match destructure_names with
        | Some [ row_name; col_name; elem_name ] ->
            bind_loop_view_fields ~loc
              [
                (row_name, row_idx_ty, i_ref);
                (col_name, col_idx_ty, j_ref);
                (elem_name, elem_ty, get2_call);
              ]
              body'
        | Some names ->
            Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
              ~hint:
                "enumerate2 yields exactly three values: row, column, and \
                 element"
              "enumerate2 tuple loop has %d binders, expected 3"
              (List.length names)
        | None ->
            let tuple =
              {
                Core.desc = CTuple [ i_ref; j_ref; get2_call ];
                ty = tup_ty;
                loc;
              }
            in
            let bind =
              {
                Core.bind_var = Core.Var.named var;
                bind_mut = false;
                bind_ty = tup_ty;
                bind_rhs = tuple;
              }
            in
            { Core.desc = CLet (bind, body'); ty = body'.ty; loc }
      in
      let inner_for =
        {
          Core.desc =
            CFor (loop_binder_for j_name col_idx_ty, inner_range, loop_body);
          ty;
          loc;
        }
      in
      {
        Core.desc =
          CFor (loop_binder_for i_name row_idx_ty, outer_range, inner_for);
        ty;
        loc;
      }
  | _ ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:"enumerate2 requires a 2D array arg"
        "enumerate2 got non-array type: %s"
        (Types.type_to_string m_ty)

(** Lower the inner statements of an [EConcurrent] into the [conc_binding]
    list carried by the Core IR [CConcurrent] node. Each binding's Core type is
    the canonical [Result[T, ConcurrencyError]] attached by [infer.ml] as the
    statement's [expr_type], even when the source annotation used an alias such
    as [TaskResult[T]]. The RHS has type [T] (the task body's return type).
    Keeping [cb_ty] canonical avoids source aliases leaking into C emission or
    downstream invariant checks. *)
and lower_concurrent_bindings (stmts : TA.expr list) : Core.conc_binding list =
  List.map
    (fun stmt ->
      match typed_expr_desc stmt with
      | TA.EConcurrentBind (name, _ty_ann, init) ->
          let parent_scope = current_task_scope_id () in
          let child_scope = fresh_task_scope_id () in
          let task_scope =
            Core.concurrent_task_scope ~parent:parent_scope ~child:child_scope
          in
          let init' =
            with_current_task_scope child_scope (fun () ->
                lower_child_expr init)
          in
          {
            Core.cb_var = Core.Var.named name;
            cb_ty = type_of_child_expr stmt;
            cb_rhs = init';
            cb_task_scope = task_scope;
            cb_task = None;
          }
      | _ ->
          Core_error.errorf (Core_error.Stage Core_stage.Lower) (TA.loc stmt)
            ~hint:
              "The typechecker should reject non-binding statements inside \
               concurrent: before Core lowering. Do not drop this statement \
               silently; that would change program behavior."
            "non-binding statement reached concurrent lowering")
    stmts

(** Tuple-destructure lowering that takes an already-lowered [body]
    (i.e., the rest of an outer block). Mirrors [lower_tuple_destruct]
    but skips the recursive [lower_block ~loc ~ty rest] call. *)
and lower_tuple_destruct_with_body ~loc names (value : TA.expr) body =
  let value' = lower_child_expr value in
  (match value'.ty with
  | TyTuple ts when List.length ts <> List.length names ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "tuple destructure names must match the tuple's arity — check the \
           typechecker let this through"
        "tuple destructure has %d names but tuple type has %d fields"
        (List.length names) (List.length ts)
  | _ -> ());
  let tmp_name = fresh_destruct_name () in
  let tmp_v = Core.Var.named tmp_name in
  let tmp_var = { Core.desc = CVar tmp_v; ty = value'.ty; loc } in
  let elem_ty i =
    match value'.ty with TyTuple ts -> List.nth ts i | _ -> value'.ty
  in
  let rec wrap_names i acc_body =
    match List.nth_opt names i with
    | None -> acc_body
    | Some n when is_wildcard_name n -> wrap_names (i + 1) acc_body
    | Some n ->
        let field_ty = elem_ty i in
        let tuple_field =
          { Core.desc = CField (tmp_var, string_of_int i); ty = field_ty; loc }
        in
        let field_bind =
          {
            Core.bind_var = Core.Var.named n;
            bind_mut = false;
            bind_ty = field_ty;
            bind_rhs = tuple_field;
          }
        in
        let inner = wrap_names (i + 1) acc_body in
        { Core.desc = CLet (field_bind, inner); ty = inner.ty; loc }
  in
  let body_with_fields = wrap_names 0 body in
  let outer_bind =
    {
      Core.bind_var = tmp_v;
      bind_mut = false;
      bind_ty = value'.ty;
      bind_rhs = value';
    }
  in
  {
    Core.desc = CLet (outer_bind, body_with_fields);
    ty = body_with_fields.ty;
    loc;
  }

(** Desugar [(a, b, ...) = value] inside a block:
    {v
    let __dt_N: T = value in
    let a: T1 = CField(__dt_N, "0") in
    let b: T2 = CField(__dt_N, "1") in
    ... rest
    v} *)
and lower_tuple_destruct ~loc ~ty names (value : TA.expr) (rest : TA.expr list)
    =
  let value' = lower_child_expr value in
  (* Validate shape upfront: the number of names must match the tuple
     arity. Previously a mismatch silently used [value'.ty] for every
     extra name and caused confusing downstream errors. *)
  (match value'.ty with
  | TyTuple ts when List.length ts <> List.length names ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc
        ~hint:
          "tuple destructure names must match the tuple's arity — check the \
           typechecker let this through"
        "tuple destructure has %d names but tuple type has %d fields"
        (List.length names) (List.length ts)
  | _ -> ());
  let tmp_name = fresh_destruct_name () in
  let tmp_v = Core.Var.named tmp_name in
  let tmp_var = { Core.desc = CVar tmp_v; ty = value'.ty; loc } in
  (* Extract element type i from a TyTuple. Shape mismatch is caught above. *)
  let elem_ty i =
    match value'.ty with
    | TyTuple ts -> List.nth ts i
    | _ -> value'.ty (* non-tuple source: type-checker should have caught it *)
  in
  (* Build nested CLets for each name = __dt.i, ending with the rest body.
     Wildcard "_" names are SKIPPED — emitting [let _ = field in ...]
     produces a real CLet whose later scope-exit cleanup tries to
     [blorp_release(_)] (a non-existent identifier in C). Mirrors the
     wildcard handling in [lower_tuple_destruct_with_body]. *)
  let rec build_bindings i = function
    | [] -> lower_block ~loc ~ty rest
    | name :: more_names when is_wildcard_name name ->
        build_bindings (i + 1) more_names
    | name :: more_names ->
        let field =
          { Core.desc = CField (tmp_var, string_of_int i); ty = elem_ty i; loc }
        in
        let bind =
          {
            Core.bind_var = Core.Var.named name;
            bind_mut = false;
            bind_ty = elem_ty i;
            bind_rhs = field;
          }
        in
        let body = build_bindings (i + 1) more_names in
        { Core.desc = CLet (bind, body); ty = body.ty; loc }
  in
  let body = build_bindings 0 names in
  let outer_bind =
    {
      Core.bind_var = tmp_v;
      bind_mut = false;
      bind_ty = value'.ty;
      bind_rhs = value';
    }
  in
  { Core.desc = CLet (outer_bind, body); ty; loc }

(* ============================================================================
   Program lowering: decls, functions, globals, impls, traits
   ============================================================================ *)

(** Lower a single parameter.

    - Named param with explicit type → [core_param] directly.
    - Pattern param (e.g. [(a, b): (Int, Int)]) → fresh temp name;
      the caller wraps the body in a [CMatchArms] that destructures it.

    Returns: [(core_param, pattern_to_match_opt)]. *)
and lower_param (p : param) : Core.core_param * Ast.pattern option =
  let pty =
    match p.param_type with
    | Some t ->
        require_final_type ~loc:p.param_loc ~context:"function parameter type" t
    | None ->
        Core_error.errorf (Core_error.Stage Core_stage.Lower) p.param_loc
          ~hint:
            "function parameters must have concrete types after typechecking; \
             check signature registration and inference."
          "param missing type"
  in
  match (p.param_name, p.param_pattern) with
  | Some name, None ->
      ( { cp_name = Core.Var.named name; cp_ty = pty; cp_loc = p.param_loc },
        None )
  | None, Some pat ->
      let fresh = fresh_param_name () in
      ( { cp_name = Core.Var.named fresh; cp_ty = pty; cp_loc = p.param_loc },
        Some pat )
  | Some _, Some _ ->
      (* Both name AND pattern — the AST shouldn't allow this, but if
         it happens we raise rather than silently dropping one. *)
      Core_error.errorf (Core_error.Stage Core_stage.Lower) p.param_loc
        ~hint:
          "a function parameter should have either a name OR a pattern, not \
           both — check the parser or typechecker output"
        "param has both a name and a pattern (ambiguous)"
  | None, None ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) p.param_loc
        ~hint:
          "a function parameter should lower from either a named binding or a \
           pattern binding; the parser/typechecker produced neither."
        "param has neither name nor pattern"

and func_decl_loc (f : Ast.func_decl) : Ast.loc =
  match f.func_body with
  | FuncBodyExpr body -> body.expr_loc
  | FuncBuiltinBody (_, loc) -> loc
  | FuncForeign _ -> (
      match f.func_params with p :: _ -> p.param_loc | [] -> Ast.dummy_loc)
  | FuncNoBody -> (
      match f.func_params with p :: _ -> p.param_loc | [] -> Ast.dummy_loc)

(** Wrap a body expression in nested [CMatchArms]es that destructure any
    pattern-typed parameters. Pattern order matches parameter order. *)
and wrap_body_with_pattern_params (body : Core.core)
    (params : (Core.core_param * Ast.pattern option) list) : Core.core =
  List.fold_right
    (fun (cp, pat_opt) acc ->
      match pat_opt with
      | None -> acc
      | Some pat ->
          let scrut =
            { Core.desc = CVar cp.Core.cp_name; ty = cp.cp_ty; loc = cp.cp_loc }
          in
          {
            Core.desc = CMatchArms (scrut, [ (pat, acc) ]);
            ty = acc.ty;
            loc = cp.cp_loc;
          })
    params body

(** Lower a function declaration after the caller has selected the semantic
    return type appropriate for its phase boundary. Raw compatibility lowering
    uses the source annotation/default rule; typed lowering uses
    [Typed_ast.func_semantic_return_type]. *)
and lower_func_with_return_ty ?typed_body ?callable_id
    ~(return_ty : Ast.type_expr) (f : Ast.func_decl) : Core.core_func =
  let name =
    match f.func_name with
    | Some n -> n
    | None ->
        Core_error.errorf (Core_error.Stage Core_stage.Lower) (func_decl_loc f)
          ~hint:
            "top-level and method function declarations must be named before \
             Core lowering; only lambda expressions are anonymous."
          "function has no name"
  in
  let params_with_pats = List.map lower_param f.func_params in
  let core_params = List.map fst params_with_pats in
  let body =
    match f.func_body with
    | FuncNoBody -> None
    | FuncBuiltinBody (BuiltinIntrinsic, _) ->
        (* [builtin] sentinel — module path is not yet set at
                lowering time, so we pass "" and let the intrinsics registry
                match on name + param types. *)
        Core_intrinsics.synthesize_body ~func_name:name ~module_path:""
          ~params:core_params ~return_ty
    | FuncBuiltinBody (BuiltinStdIntrinsic identity, _) -> (
        match
          Core_intrinsics.synthesize_std_body
            ~module_path:identity.std_builtin_module_path
            ~func_name:identity.std_builtin_func_name ~params:core_params
            ~return_ty
        with
        | Core_intrinsics.StdBuiltinBody body ->
            Some (wrap_body_with_pattern_params body params_with_pats)
        | Core_intrinsics.StdBuiltinNoBody -> None)
    | FuncBuiltinBody (BuiltinRuntimeHelper cname, loc) ->
        (* [builtin("cname")] forwards declared parameters to the named C
           runtime helper. Std compiler intrinsics use [BuiltinStdIntrinsic]
           instead, so this branch does not inspect naming conventions. *)
        let dummy_callee =
          { Core.desc = CVoid; ty = Ast.TyNamed ("Void", []); loc }
        in
        let param_args =
          List.map
            (fun (cp : Core.core_param) ->
              { Core.desc = CVar cp.cp_name; ty = cp.cp_ty; loc = cp.cp_loc })
            core_params
        in
        let call =
          {
            Core.desc = CCall (CKBuiltin cname, dummy_callee, param_args);
            ty = return_ty;
            loc;
          }
        in
        Some (wrap_body_with_pattern_params call params_with_pats)
    | FuncForeign _ -> None
    | FuncBodyExpr body_expr ->
        let body_expr =
          match typed_body with
          | Some typed_body -> typed_body
          | None -> require_typed_expr body_expr
        in
        let body' = lower_child_expr body_expr in
        Some (wrap_body_with_pattern_params body' params_with_pats)
  in
  (* Exactly one of: foreign / builtin / user. Foreign wins over builtin,
     matching the prior emit-site precedence. A synthesized IR body demotes
     a builtin to user-kind — matches the prior [... && body = None] gate. *)
  let kind : Core.cf_kind =
    match f.func_body with
    | FuncForeign { foreign_name; foreign_includes; foreign_link_flags } ->
        let arg_passing =
          if f.func_is_pure || f.func_no_copy then Core.ForeignBorrowArgs
          else Core.ForeignDefaultArgs []
        in
        CFForeign
          {
            c_name = foreign_name;
            includes = foreign_includes;
            link_flags = foreign_link_flags;
            arg_passing;
          }
    | FuncBodyExpr _ | FuncBuiltinBody _ | FuncNoBody ->
        let has_no_body = body = None in
        let source_is_builtin =
          match f.func_body with
          | FuncBuiltinBody _ -> true
          | FuncBodyExpr _ | FuncForeign _ | FuncNoBody -> false
        in
        if source_is_builtin && has_no_body then CFBuiltin else CFUser
  in
  let cf_def_id =
    match callable_id with
    | Some id -> id
    | None -> Session.mint_def_id (Session.current ())
  in
  {
    cf_name = name;
    cf_module = None;
    (* populated later by Core_flatten.prefix_module_names *)
    cf_type_params = f.func_type_params;
    cf_params = core_params;
    cf_return_ty = return_ty;
    cf_body = body;
    cf_is_pure = f.func_is_pure;
    cf_kind = kind;
    cf_def_id;
  }

(** Lower a raw AST function declaration. This is the compatibility path used
    by legacy tests and wrappers before a typed function payload is available. *)
and lower_func (f : Ast.func_decl) : Core.core_func =
  let return_ty =
    match f.func_return_type with
    | Some t ->
        require_final_type ~loc:(func_decl_loc f)
          ~context:"function return type" t
    | None -> Ast.TyNamed ("Void", [])
  in
  lower_func_with_return_ty ~return_ty f

(** Lower a typed function declaration. Source annotation absence is not
    reinterpreted here; the semantic return type was established by inference
    and validated at the [Typed_ast] boundary. *)
and lower_typed_func (typed : Typed_ast.func_decl) : Core.core_func =
  let f = Typed_ast.func_ast typed in
  let return_ty =
    require_final_type ~loc:(func_decl_loc f)
      ~context:"function semantic return type"
      (Typed_ast.func_semantic_return_type typed)
  in
  let typed_body =
    match Typed_ast.func_body_expr typed with
    | Ok typed_body -> typed_body
    | Error err -> typed_ast_error err
  in
  let callable_id = Typed_ast.func_callable_id typed in
  lower_func_with_return_ty ?typed_body ?callable_id ~return_ty f

(** Lower a global variable declaration. *)
and lower_var (v : Ast.var_decl) : Core.core_var =
  let name =
    match v.var_name with
    | Some n -> n
    | None ->
        Core_error.errorf (Core_error.Stage Core_stage.Lower)
          v.var_value.expr_loc
          ~hint:
            "global pattern bindings are not representable as a single Core \
             global variable. Destructure inside a function body or add \
             explicit lowering support for multiple globals."
          "global var with pattern binding not supported yet"
  in
  let init = lower_ast_binding_init v.var_type v.var_value in
  let ty =
    match v.var_type with
    | Some t ->
        require_final_type ~loc:v.var_value.expr_loc
          ~context:"global variable annotation" t
    | None -> init.ty
  in
  {
    cv_name = Core.Var.named name;
    cv_module = None;
    cv_ty = ty;
    cv_init = init;
    cv_is_mutable = v.var_is_mutable;
    cv_is_const = v.var_is_const;
    cv_def_id = Session.mint_def_id (Session.current ());
  }

(** Lower a typed global variable declaration. The binding slot type may come
    from an inferred value slot, not only from a source annotation. *)
and lower_typed_var (typed : Typed_ast.var_decl) : Core.core_var =
  let v = Typed_ast.var_ast typed in
  let name =
    match v.var_name with
    | Some n -> n
    | None ->
        Core_error.errorf (Core_error.Stage Core_stage.Lower)
          v.var_value.expr_loc
          ~hint:
            "global pattern bindings are not representable as a single Core \
             global variable. Destructure inside a function body or add \
             explicit lowering support for multiple globals."
          "global var with pattern binding not supported yet"
  in
  let ty =
    require_final_type ~loc:v.var_value.expr_loc
      ~context:"global variable binding type"
      (Typed_ast.var_binding_type typed)
  in
  let value =
    match Typed_ast.var_value_expr typed with
    | Ok value -> value
    | Error err -> typed_ast_error err
  in
  let init = lower_binding_init (Some ty) value in
  {
    cv_name = Core.Var.named name;
    cv_module = None;
    cv_ty = ty;
    cv_init = init;
    cv_is_mutable = v.var_is_mutable;
    cv_is_const = v.var_is_const;
    cv_def_id = Session.mint_def_id (Session.current ());
  }

(** Lower an impl block: each method body is lowered. *)
and lower_impl (i : Ast.impl_decl) : Core.core_impl =
  {
    ci_trait = i.impl_trait;
    ci_for_type = i.impl_for_type;
    ci_methods = List.map lower_func i.impl_methods;
  }

(** Lower a typed impl block. Method bodies use typed function metadata, so
    inferred method return types cannot be reinterpreted from raw AST
    annotations here. *)
and lower_typed_impl (typed : Typed_ast.impl_decl) : Core.core_impl =
  let i = Typed_ast.impl_ast typed in
  {
    ci_trait = i.impl_trait;
    ci_for_type = i.impl_for_type;
    ci_methods = List.map lower_typed_func (Typed_ast.impl_methods typed);
  }

(** Lower a trait method signature. Default bodies stay on the AST
    [trait_method] and are only ever consumed by [Typecheck]'s
    default-method synthesizer — Core IR carries only the signature. *)
and lower_trait_method (m : Ast.trait_method) : Core.core_trait_method =
  let params_with_pats = List.map lower_param m.method_params in
  let core_params = List.map fst params_with_pats in
  {
    ctm_name = m.method_name;
    ctm_params = core_params;
    ctm_return_ty = m.method_return_type;
    ctm_is_pure = m.method_is_pure;
  }

(** Lower a trait declaration. *)
and lower_trait (t : Ast.trait_decl) : Core.core_trait =
  {
    ct_name = t.trait_name;
    ct_type_params = Ast.type_param_names t.trait_type_params;
    ct_supertraits = t.trait_supertraits;
    ct_methods = List.map lower_trait_method t.trait_methods;
  }

(** Lower a top-level declaration after [Typed_ast] validation. *)
and lower_decl_ast (d : Ast.decl) : Core.core_decl =
  let desc =
    match d.decl_desc with
    | DFunc f -> Core.CDFunc (lower_func f)
    | DVar v -> Core.CDVar (lower_var v)
    | DImpl i -> Core.CDImpl (lower_impl i)
    | DTrait t -> Core.CDTrait (lower_trait t)
    | DType t -> Core.CDType t (* pass-through *)
    | DRecord r -> Core.CDRecord r (* pass-through *)
    | DImport i -> Core.CDImport i (* pass-through *)
    | DTypeAlias a -> Core.CDTypeAlias a (* pass-through *)
    | DPrivate inner -> Core.CDPrivate (lower_decl_ast inner)
  in
  { cd_desc = desc; cd_loc = d.decl_loc; cd_doc = d.decl_doc }

and lower_typed_decl_core (typed : Typed_ast.decl) : Core.core_decl =
  let ast_decl = Typed_ast.decl_ast typed in
  let desc =
    match Typed_ast.decl_view typed with
    | Typed_ast.DeclFunction func -> Core.CDFunc (lower_typed_func func)
    | Typed_ast.DeclVar var -> Core.CDVar (lower_typed_var var)
    | Typed_ast.DeclRecord record -> Core.CDRecord (Typed_ast.record_ast record)
    | Typed_ast.DeclTypeAlias alias ->
        Core.CDTypeAlias (Typed_ast.type_alias_ast alias)
    | Typed_ast.DeclImpl impl -> Core.CDImpl (lower_typed_impl impl)
    | Typed_ast.DeclPrivate inner ->
        Core.CDPrivate (lower_typed_decl_core inner)
    | Typed_ast.DeclOther -> (lower_decl_ast ast_decl).cd_desc
  in
  { cd_desc = desc; cd_loc = ast_decl.decl_loc; cd_doc = ast_decl.decl_doc }

and decl_label d =
  match d.Ast.decl_desc with
  | Ast.DFunc f -> "func " ^ Option.value f.func_name ~default:"?"
  | Ast.DVar v -> "var " ^ Option.value v.var_name ~default:"?"
  | Ast.DType t -> "type " ^ t.type_name
  | _ -> "decl"

and lower_decl_with_error (d : Ast.decl) lower =
  try lower () with
  | Core_error.Core_error _ as exn -> raise exn
  | Failure msg ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) d.decl_loc
        ~hint:
          "Core lowering must either translate the declaration or report the \
           unsupported shape; silently dropping it would produce a partial \
           program."
        "lowering failed for %s: %s" (decl_label d) msg

let lower_typed_expr (typed : Typed_ast.expr) : Core.core =
  lower_typed_expr_core typed

let lower_typed_decl (typed : Typed_ast.decl) : Core.core_decl =
  lower_typed_decl_core typed

let lower_typed_program (typed : Typed_ast.program) : Core.core_program =
  typed |> Typed_ast.program_decls
  |> List.map (fun typed_decl ->
      let ast_decl = Typed_ast.decl_ast typed_decl in
      lower_decl_with_error ast_decl (fun () ->
          lower_typed_decl_core typed_decl))
