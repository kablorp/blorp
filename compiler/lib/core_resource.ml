(** Resource-scope cleanup edge rewriting.

    [CResourceScope] owns semantic cleanup for normal completion directly. This
    pass handles loop-control exits that leave a resource scope before its
    normal trailing cleanup can run. It rewrites those exits into explicit
    [CResourceCleanupExit] nodes carrying the active cleanup stack.

    Loop bodies are barriers for outer cleanup stacks: a [break] or [continue]
    inside a nested [while]/[for]/tailrec loop targets that loop, not the
    enclosing resource scope. Resource scopes nested inside those loops add
    their own cleanup stack again. *)

open Core

let rec rewrite_nonlocal_exits_expr ?(cleanups = []) (expr : core) : core =
  let rewrite = rewrite_nonlocal_exits_expr ~cleanups in
  let rewrite_loop_body body = rewrite_nonlocal_exits_expr ~cleanups:[] body in
  let cleanup_exit rce_exit exit =
    match cleanups with
    | [] -> exit
    | _ :: _ ->
        {
          exit with
          desc = CResourceCleanupExit { rce_cleanups = cleanups; rce_exit };
        }
  in
  match expr.desc with
  | CBreak -> cleanup_exit ResourceBreak expr
  | CContinue -> cleanup_exit ResourceContinue expr
  | CResourceCleanupExit _ -> expr
  | CResourceScope scope ->
      {
        expr with
        desc =
          CResourceScope
            {
              scope with
              rs_acquire = rewrite scope.rs_acquire;
              rs_body =
                rewrite_nonlocal_exits_expr
                  ~cleanups:(scope.rs_cleanup :: cleanups)
                  scope.rs_body;
              rs_cleanup = rewrite scope.rs_cleanup;
            };
      }
  | CWhile (cond, body) ->
      { expr with desc = CWhile (rewrite cond, rewrite_loop_body body) }
  | CFor (binder, iter, body) ->
      { expr with desc = CFor (binder, rewrite iter, rewrite_loop_body body) }
  | CTailrecLoop loop ->
      let loop' =
        match loop with
        | TailrecUnmanagedLoop l ->
            TailrecUnmanagedLoop
              { l with tul_body = rewrite_loop_body l.tul_body }
        | TailrecListSpreadLoop l ->
            TailrecListSpreadLoop
              { l with tls_body = rewrite_loop_body l.tls_body }
      in
      { expr with desc = CTailrecLoop loop' }
  | CMatchArms (scrutinee, arms) ->
      {
        expr with
        desc =
          CMatchArms
            ( rewrite scrutinee,
              List.map (fun (pat, body) -> (pat, rewrite body)) arms );
      }
  | CMatch (scrutinee, tree) ->
      {
        expr with
        desc = CMatch (rewrite scrutinee, rewrite_ctree ~cleanups tree);
      }
  | _ -> Core.map_children rewrite expr

and rewrite_ctree ~cleanups (tree : ctree) : ctree =
  match tree with
  | CTLeaf leaf ->
      CTLeaf
        {
          leaf with
          ct_body = rewrite_nonlocal_exits_expr ~cleanups leaf.ct_body;
        }
  | CTFail -> CTFail
  | CTSwitchTag t ->
      CTSwitchTag
        {
          t with
          cts_cases =
            List.map
              (fun (ctor, subtree) -> (ctor, rewrite_ctree ~cleanups subtree))
              t.cts_cases;
          cts_default = Option.map (rewrite_ctree ~cleanups) t.cts_default;
        }
  | CTSwitchLit t ->
      CTSwitchLit
        {
          t with
          ctl_cases =
            List.map
              (fun (lit, subtree) -> (lit, rewrite_ctree ~cleanups subtree))
              t.ctl_cases;
          ctl_default = rewrite_ctree ~cleanups t.ctl_default;
        }
  | CTSwitchLen t ->
      CTSwitchLen
        {
          t with
          ctl_len_cases =
            List.map
              (fun (len, subtree) -> (len, rewrite_ctree ~cleanups subtree))
              t.ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (len, subtree) -> (len, rewrite_ctree ~cleanups subtree))
              t.ctl_len_geq;
          ctl_len_default =
            Option.map (rewrite_ctree ~cleanups) t.ctl_len_default;
        }

let rec rewrite_nonlocal_exits_decl (decl : core_decl) : core_decl =
  let rewrite_func f =
    { f with cf_body = Option.map rewrite_nonlocal_exits_expr f.cf_body }
  in
  let desc =
    match decl.cd_desc with
    | CDFunc f -> CDFunc (rewrite_func f)
    | CDVar v ->
        CDVar { v with cv_init = rewrite_nonlocal_exits_expr v.cv_init }
    | CDImpl impl ->
        CDImpl { impl with ci_methods = List.map rewrite_func impl.ci_methods }
    | CDPrivate inner -> CDPrivate (rewrite_nonlocal_exits_decl inner)
    | (CDTrait _ | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _) as desc
      ->
        desc
  in
  { decl with cd_desc = desc }

let rewrite_nonlocal_exits_program (prog : core_program) : core_program =
  List.map rewrite_nonlocal_exits_decl prog
