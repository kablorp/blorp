(** Cooperative-fairness checkpoint insertion.

    This pass inserts compiler-owned cancellation/yield checkpoints into loop
    bodies. The checkpoint is represented as [CCooperativeCheckpoint], not as a
    source-level [yield_now()] call, so purity checking remains a source
    language property and the runtime owns the reduction budget. *)

open Core

let checkpoint_at loc = Build.cooperative_checkpoint ~loc

let body_start_kind (body : core) : Core_fairness_blorp_policy.body_start =
  match body.desc with
  | CCooperativeCheckpoint -> BodyCheckpoint
  | CSeq ({ desc = CCooperativeCheckpoint; _ }, _) -> BodySeqCheckpoint
  | _ -> BodyOther

let body_starts_with_checkpoint (body : core) : bool =
  Core_fairness_blorp_policy.body_starts_with_checkpoint (body_start_kind body)

let add_loop_checkpoint (loop_loc : Ast.loc) (body : core) : core =
  if body_starts_with_checkpoint body then body
  else
    { desc = CSeq (checkpoint_at loop_loc, body); ty = body.ty; loc = body.loc }

let add_tailrec_loop_checkpoint (loop_loc : Ast.loc) (loop : tailrec_loop) :
    tailrec_loop =
  match loop with
  | TailrecUnmanagedLoop l ->
      TailrecUnmanagedLoop
        { l with tul_body = add_loop_checkpoint loop_loc l.tul_body }
  | TailrecListSpreadLoop l ->
      TailrecListSpreadLoop
        { l with tls_body = add_loop_checkpoint loop_loc l.tls_body }

let rec rewrite_expr (expr : core) : core =
  let expr = map_children rewrite_expr expr in
  match expr.desc with
  | CWhile (cond, body) ->
      { expr with desc = CWhile (cond, add_loop_checkpoint expr.loc body) }
  | CFor (binder, iter, body) ->
      {
        expr with
        desc = CFor (binder, iter, add_loop_checkpoint expr.loc body);
      }
  | CTailrecLoop loop ->
      {
        expr with
        desc = CTailrecLoop (add_tailrec_loop_checkpoint expr.loc loop);
      }
  | _ -> expr

let rewrite_func (f : core_func) : core_func =
  match f.cf_body with
  | Some body -> { f with cf_body = Some (rewrite_expr body) }
  | None -> f

let rewrite_impl (impl : core_impl) : core_impl =
  { impl with ci_methods = List.map rewrite_func impl.ci_methods }

let rec rewrite_decl (decl : core_decl) : core_decl =
  match decl.cd_desc with
  | CDFunc f -> { decl with cd_desc = CDFunc (rewrite_func f) }
  | CDImpl impl -> { decl with cd_desc = CDImpl (rewrite_impl impl) }
  | CDPrivate inner -> { decl with cd_desc = CDPrivate (rewrite_decl inner) }
  | CDVar _ | CDTrait _ | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _ ->
      decl

let insert_program_checkpoints (prog : core_program) : core_program =
  List.map rewrite_decl prog
