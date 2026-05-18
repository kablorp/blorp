(** Core IR desugaring passes.

    Runs after [Core_lower] and before [Core_match] / [Core_perceus].
    Rewrites sugar nodes into simpler Core primitives so that downstream
    passes (and [Core_emit]) see a smaller, more regular IR surface.

    {1 Passes}

    - {b Record update}: [CRecordUpdate(base, updates)] →
      [CLet(tmp, base, CRecord(all_fields))] with explicit field reads
      for unchanged fields. Requires record declarations from the
      program to know the full field list.

    - {b String interpolation}: [CStringInterp(parts, _)] → chain of
      to_string calls + [blorp_string_concat_consume] (2 parts) or
      [blorp_string_concat_many] (3+). String expressions pass through;
      other expressions are converted with concrete to-string helpers or
      the [blorp_to_string] sentinel resolved by [Core_specialize].

    Direct [?=] propagation is lowered before this pass by [Core_lower]. *)

open Core

(** Fresh-id counter migrated to [Session.t] (T1.4 — 2026-04-21).
    Previously module-level [ref 0] with a [reset_counter] helper
    called at [desugar_program] entry. *)

let fresh_id () =
  let s = Session.current () in
  let n = s.desugar_counter in
  s.desugar_counter <- n + 1;
  n

(** Build a map from record name to its field declarations. *)
let build_field_map (prog : core_program) :
    (string, Ast.field_decl list) Hashtbl.t =
  let map = Hashtbl.create 16 in
  let rec add_decl d =
    match d.cd_desc with
    | CDRecord r -> Hashtbl.replace map r.record_name r.record_fields
    | CDPrivate inner -> add_decl inner
    | _ -> ()
  in
  List.iter add_decl prog;
  map

(** Rewrite a single [CRecordUpdate] into [CLet + CRecord].

    Given [{ base | f1 = v1, f2 = v2 }] where the record has fields
    [f1, f2, f3], produces:

    {[
      let __upd_N = base in
      Record_make(v1, v2, __upd_N.f3)
    ]}

    Raises a structured Desugar error if the record declaration is missing.
    The post-desugar invariant rejects surviving [CRecordUpdate], so leaving
    the node in place would only defer the failure to a less useful phase. *)
let record_update_type_name (e : core) : string =
  match Codegen_types.normalize_type e.ty with
  | Ast.TyNamed (n, _) -> n
  | other ->
      Core_error.errorf (Core_error.Stage Core_stage.Desugar) e.loc
        ~hint:
          "Record update syntax must have a named record type after \
           typechecking. If this Core was hand-built, attach the concrete \
           record type; otherwise the typechecker let an invalid record update \
           through."
        "record update target has non-record type %s"
        (Types.type_to_string other)

let desugar_record_update (field_map : (string, Ast.field_decl list) Hashtbl.t)
    (e : core) : core =
  match e.desc with
  | CRecordUpdate (base, updates) -> (
      let type_name = record_update_type_name e in
      match Hashtbl.find_opt field_map type_name with
      | None ->
          Core_error.errorf (Core_error.Stage Core_stage.Desugar) e.loc
            ~hint:
              "Core_desugar needs the full record declaration to materialize \
               unchanged fields. Normal compilation should include the \
               declaring module before this pass; if this is a unit test, add \
               the CDRecord declaration to the program."
            "record update for unknown record type %s" type_name
      | Some fields ->
          let id = fresh_id () in
          let tmp = Var.named (Printf.sprintf "__upd_%d" id) in
          let tmp_ref = { desc = CVar tmp; ty = e.ty; loc = e.loc } in
          let all_fields =
            List.map
              (fun (fd : Ast.field_decl) ->
                match List.assoc_opt fd.field_name updates with
                | Some v -> (fd.field_name, v)
                | None ->
                    let read =
                      {
                        desc = CField (tmp_ref, fd.field_name);
                        ty = fd.field_type;
                        loc = e.loc;
                      }
                    in
                    (fd.field_name, read))
              fields
          in
          let record = { desc = CRecord all_fields; ty = e.ty; loc = e.loc } in
          let binding =
            {
              bind_var = tmp;
              bind_mut = false;
              bind_ty = e.ty;
              bind_rhs = base;
            }
          in
          { desc = CLet (binding, record); ty = e.ty; loc = e.loc })
  | _ -> e

(* ============================================================================
   String interpolation desugaring
   ============================================================================ *)

let ty_string = Ast.TyNamed ("String", [])
let ty_int = Ast.TyNamed ("Int", [])
let str_flags = { Ast.sf_triple = false; sf_raw = false }

(** Map a type to its runtime to_string function name.
    Returns [None] for String (identity). All other types use
    [blorp_to_string] as a sentinel that [core_specialize] will
    dispatch to the concrete per-type function. *)
let to_string_fn (ty : Ast.type_expr) : string option =
  match Codegen_types.normalize_type ty with
  | Ast.TyNamed ("String", []) -> None
  | Ast.TyNamed ("Int", []) -> Some "blorp_to_string"
  | Ast.TyNamed ("Float", []) -> Some "blorp_float_to_string"
  | Ast.TyNamed ("Float32", []) -> Some "blorp_float32_to_string"
  | Ast.TyNamed ("Float16", []) -> Some "blorp_float16_to_string"
  | Ast.TyNamed ("Bool", []) -> Some "blorp_bool_to_string"
  | Ast.TyNamed ("Char", []) -> Some "blorp_from_char"
  | Ast.TyNamed ("Int128", []) -> Some "blorp_int128_to_string"
  | Ast.TyNamed ("UInt128", []) -> Some "blorp_uint128_to_string"
  | ty when Types.is_any_integer_type ty -> Some "blorp_to_string"
  (* All other types — core_specialize dispatches blorp_to_string
     to the correct per-type Stringable implementation. *)
  | _ -> Some "blorp_to_string"

(** Wrap [expr] in a [CKBuiltin] call to [fn_name]. *)
let builtin_call fn_name args result_ty loc =
  let dummy = { desc = CVoid; ty = Ast.TyNamed ("Void", []); loc } in
  { desc = CCall (CKBuiltin fn_name, dummy, args); ty = result_ty; loc }

(** Convert a single interpolation part to a [blorp_String*] expression. *)
let convert_interp_part (loc : Ast.loc) = function
  | IPLit s ->
      { desc = CLit (Ast.LitString (s, str_flags)); ty = ty_string; loc }
  | IPExpr expr -> (
      match to_string_fn expr.ty with
      | None -> expr
      | Some fn -> builtin_call fn [ expr ] ty_string loc)

(** Desugar [CStringInterp] into concat calls.

    - 0 parts → empty string literal
    - 1 part → that part (already a String)
    - 2 parts → [blorp_string_concat_consume(a, b)]
    - 3+ parts → [blorp_string_concat_many(count, a, b, c, ...)]

    All types are handled — unknown types use [blorp_to_string] which
    [core_specialize] dispatches to the correct implementation. *)
let desugar_string_interp (e : core) : core =
  match e.desc with
  | CStringInterp (parts, _) -> (
      let converted = List.map (convert_interp_part e.loc) parts in
      match converted with
      | [] ->
          {
            desc = CLit (Ast.LitString ("", str_flags));
            ty = ty_string;
            loc = e.loc;
          }
      | [ single ] -> single
      | [ a; b ] ->
          builtin_call "blorp_string_concat_consume" [ a; b ] ty_string e.loc
      | many ->
          let count =
            {
              desc = CLit (Ast.LitInt (Int64.of_int (List.length many)));
              ty = ty_int;
              loc = e.loc;
            }
          in
          builtin_call "blorp_string_concat_many" (count :: many) ty_string
            e.loc)
  | _ -> e

(* ============================================================================
   String binary operator desugaring
   ============================================================================ *)

let is_string_ty ty =
  Codegen_types.normalize_type ty = Ast.TyNamed ("String", [])

let desugar_string_binop (e : core) : core =
  match e.desc with
  | CBin (Ast.Add, l, r) when is_string_ty l.ty ->
      builtin_call "blorp_string_concat" [ l; r ] ty_string e.loc
  | CBin (Ast.Eq, l, r) when is_string_ty l.ty ->
      let ty_bool = Ast.TyNamed ("Bool", []) in
      builtin_call "blorp_string_eq" [ l; r ] ty_bool e.loc
  | CBin (Ast.Ne, l, r) when is_string_ty l.ty ->
      let ty_bool = Ast.TyNamed ("Bool", []) in
      let eq = builtin_call "blorp_string_eq" [ l; r ] ty_bool e.loc in
      { desc = CUn (Ast.Not, eq); ty = ty_bool; loc = e.loc }
  | _ -> e

(* ============================================================================
   Legacy try-block desugaring — REMOVED in Phase 2.9 (2026-04-21)

   Direct [?=] statements are now fully desugared at lower time by
   [Core_lower.lower_question_bind]. [splice_continuation] is deleted with the
   rest of this section. *)

(* ============================================================================
   Expression-level desugaring driver
   ============================================================================ *)

(** Desugar sugar nodes in an expression (record updates + string interp). *)
let desugar_expr (field_map : (string, Ast.field_decl list) Hashtbl.t)
    (e : core) : core =
  transform_bottom_up
    (fun node ->
      let node = desugar_record_update field_map node in
      let node = desugar_string_interp node in
      desugar_string_binop node)
    e

(** Desugar record updates in a function body. *)
let desugar_func (field_map : (string, Ast.field_decl list) Hashtbl.t)
    (f : core_func) : core_func =
  match f.cf_body with
  | None -> f
  | Some body -> { f with cf_body = Some (desugar_expr field_map body) }

(** Desugar record updates in a single declaration. *)
let rec desugar_decl (field_map : (string, Ast.field_decl list) Hashtbl.t)
    (d : core_decl) : core_decl =
  let desc' =
    match d.cd_desc with
    | CDFunc f -> CDFunc (desugar_func field_map f)
    | CDVar v -> CDVar { v with cv_init = desugar_expr field_map v.cv_init }
    | CDImpl i ->
        CDImpl
          { i with ci_methods = List.map (desugar_func field_map) i.ci_methods }
    | CDTrait _ as other ->
        other (* no expressions to desugar; defaults live on AST *)
    | CDPrivate inner -> CDPrivate (desugar_decl field_map inner)
    | (CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _) as other -> other
  in
  { d with cd_desc = desc' }

(** Desugar a whole program. Builds the field map from declarations,
    then rewrites all [CRecordUpdate] nodes. Counter reset moved to
    [Core_pipeline] — see [Session.reset_core_counters]. *)
let desugar_program (prog : core_program) : core_program =
  let field_map = build_field_map prog in
  List.map (desugar_decl field_map) prog

(* The mutable-variable SSA-like renaming pass that used to live here
   moved to [core_ssa.ml] in Phase 5.4. It's structurally independent
   from sugar elimination — different entry point, different tests,
   different downstream consumers — so the split clarifies the
   pass-by-pass story without changing any behavior. *)
