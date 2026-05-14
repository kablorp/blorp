(** Debug-block lowering for Core.

    Source [debug:] blocks are represented explicitly as [CDebugBlock] after
    [Core_lower]. This pass is the only place that decides whether the block
    is retained or erased:

    - normal builds replace [CDebugBlock body] with [CVoid]
    - debug builds replace [CDebugBlock body] with [body]

    Keeping that decision in Core gives every backend the same semantics and
    lets invariant checks reject any debug block that survives this stage. *)

open Core

let void_ty = Ast.TyNamed ("Void", [])
let void_at (e : core) : core = { desc = CVoid; ty = void_ty; loc = e.loc }

let lower_expr ~(enabled : bool) (expr : core) : core =
  transform_bottom_up
    (fun e ->
      match e.desc with
      | CDebugBlock body -> if enabled then body else void_at e
      | _ -> e)
    expr

let lower_func ~(enabled : bool) (f : core_func) : core_func =
  { f with cf_body = Option.map (lower_expr ~enabled) f.cf_body }

let rec lower_decl ~(enabled : bool) (d : core_decl) : core_decl =
  let desc =
    match d.cd_desc with
    | CDFunc f -> CDFunc (lower_func ~enabled f)
    | CDVar v -> CDVar { v with cv_init = lower_expr ~enabled v.cv_init }
    | CDImpl impl ->
        CDImpl
          {
            impl with
            ci_methods = List.map (lower_func ~enabled) impl.ci_methods;
          }
    | CDPrivate inner -> CDPrivate (lower_decl ~enabled inner)
    | (CDTrait _ | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _) as other
      ->
        other
  in
  { d with cd_desc = desc }

let lower_program ~(enabled : bool) (prog : core_program) : core_program =
  List.map (lower_decl ~enabled) prog
