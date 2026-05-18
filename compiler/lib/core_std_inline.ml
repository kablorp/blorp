(** Narrow call-site expansion for compiler-owned std functions.

    This is deliberately not a general inliner. It only expands a small
    allowlist of standard-library functions whose Core bodies are part of the
    collection representation contract. The goal is to expose collection
    ownership/layout operations to later Core passes without guessing from C code
    or relying on the C compiler to inline across generated std wrappers.

    Inlining preserves the wrapper's ownership contract explicitly. Read-only
    arguments can borrow existing variables to avoid retain/read/release noise.
    COW-consuming variable receivers, such as [append]'s list receiver, are
    substituted directly into the cloned body so Perceus sees the actual owner at
    the consume intrinsic instead of an alias. Non-variable consuming receivers
    still use owned bindings to preserve single evaluation. *)

open Core

type inline_arg_binding =
  | Borrow_existing_var
  | Own_binding
  | Substitute_existing_var

type target = {
  params : core_param list;
  arg_bindings : inline_arg_binding list;
  body : core;
}

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

let source_name (f : core_func) =
  let name = strip_mono_suffix f.cf_name in
  let name =
    match f.cf_module with
    | None -> name
    | Some module_path ->
        let prefix = Codegen_names.sanitize_module_name module_path ^ "__" in
        if starts_with name prefix then
          String.sub name (String.length prefix)
            (String.length name - String.length prefix)
        else name
  in
  let pure_suffix = "__pure" in
  if ends_with name pure_suffix then
    String.sub name 0 (String.length name - String.length pure_suffix)
  else name

let readonly_arg_bindings params =
  List.map (fun _ -> Borrow_existing_var) params

let list_append_arg_bindings = function
  | _receiver :: rest ->
      (* Append consumes its receiver through list_ensure_unique/list_set_owned.
         If the receiver is already a variable, substitute it into the cloned
         body so Perceus sees the original owner rather than an alias. *)
      Some (Substitute_existing_var :: readonly_arg_bindings rest)
  | [] -> None

let std_list_arg_bindings source_name params =
  match source_name with
  | "length" | "get_or" | "__unsafe_list_get" ->
      Some (readonly_arg_bindings params)
  | "append" | "__unsafe_list_append" -> list_append_arg_bindings params
  | _ -> None

let std_tensor_arg_bindings source_name params =
  match source_name with
  | "get_or" -> Some (readonly_arg_bindings params)
  | _ -> None

let compiler_owned_module = function
  | Some module_path ->
      starts_with module_path "std/" || starts_with module_path "pkg/"
  | None -> false

let collect_targets (prog : core_program) : (int, target) Hashtbl.t =
  let targets = Hashtbl.create 16 in
  let remember_func (f : core_func) =
    match (f.cf_module, f.cf_body, f.cf_type_params) with
    | Some "std/list", Some body, [] -> (
        match std_list_arg_bindings (source_name f) f.cf_params with
        | Some arg_bindings ->
            Hashtbl.replace targets f.cf_def_id
              { params = f.cf_params; arg_bindings; body }
        | None -> ())
    | Some "std/tensor", Some body, [] -> (
        match std_tensor_arg_bindings (source_name f) f.cf_params with
        | Some arg_bindings ->
            Hashtbl.replace targets f.cf_def_id
              { params = f.cf_params; arg_bindings; body }
        | None -> ())
    | _ -> ()
  in
  let rec visit_decl d =
    match d.cd_desc with
    | CDFunc f -> remember_func f
    | CDPrivate inner -> visit_decl inner
    | _ -> ()
  in
  List.iter visit_decl prog;
  targets

type clone_state = { mutable next_id : int }

let fresh_var state (v : var) : var =
  state.next_id <- state.next_id + 1;
  { vname = "__std_inline_" ^ v.vname; vuniq = state.next_id; vdef_id = None }

let lookup_var env v =
  List.find_map
    (fun (old_v, new_v) -> if Var.equal old_v v then Some new_v else None)
    env

let rename_existing_var env v = Option.value (lookup_var env v) ~default:v

let rename_binder state env v =
  let v' = fresh_var state v in
  (v', (v, v') :: env)

let rename_params state env params =
  List.fold_left
    (fun (renamed, env) p ->
      let cp_name, env = rename_binder state env p.cp_name in
      ({ p with cp_name } :: renamed, env))
    ([], env) params
  |> fun (renamed, env) -> (List.rev renamed, env)

let rec clone_ctree state env tree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let bindings, env =
        List.fold_left
          (fun (bindings, env) (v, acc) ->
            let v', env = rename_binder state env v in
            ((v', acc) :: bindings, env))
          ([], env) ct_bindings
      in
      CTLeaf
        {
          ct_bindings = List.rev bindings;
          ct_body = clone_expr state env ct_body;
        }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map (fun (n, t) -> (n, clone_ctree state env t)) cts_cases;
          cts_default = Option.map (clone_ctree state env) cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map (fun (l, t) -> (l, clone_ctree state env t)) ctl_cases;
          ctl_default = clone_ctree state env ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map (fun (n, t) -> (n, clone_ctree state env t)) ctl_len_cases;
          ctl_len_geq =
            Option.map (fun (n, t) -> (n, clone_ctree state env t)) ctl_len_geq;
          ctl_len_default = Option.map (clone_ctree state env) ctl_len_default;
        }

and clone_expr state env e =
  let clone = clone_expr state in
  match e.desc with
  | CVar v -> { e with desc = CVar (rename_existing_var env v) }
  | CLet (binding, body) ->
      let rhs = clone env binding.bind_rhs in
      let bind_var, body_env = rename_binder state env binding.bind_var in
      let body = clone body_env body in
      { e with desc = CLet ({ binding with bind_var; bind_rhs = rhs }, body) }
  | CBorrowLet (binding, body) ->
      let rhs = clone env binding.borrow_rhs in
      let borrow_var, body_env = rename_binder state env binding.borrow_var in
      let body = clone body_env body in
      {
        e with
        desc = CBorrowLet ({ binding with borrow_var; borrow_rhs = rhs }, body);
      }
  | CTensorRawViewLet (binding, body) ->
      let source = clone env binding.trv_source in
      let trv_var, body_env = rename_binder state env binding.trv_var in
      let body = clone body_env body in
      {
        e with
        desc =
          CTensorRawViewLet ({ binding with trv_var; trv_source = source }, body);
      }
  | CTensorRawRead r ->
      {
        e with
        desc =
          CTensorRawRead
            {
              r with
              trr_view = rename_existing_var env r.trr_view;
              trr_index = clone env r.trr_index;
            };
      }
  | CTensorRawWrite w ->
      {
        e with
        desc =
          CTensorRawWrite
            {
              w with
              trw_view = rename_existing_var env w.trw_view;
              trw_index = clone env w.trw_index;
              trw_value = clone env w.trw_value;
            };
      }
  | CLambda lam ->
      let params, body_env =
        List.fold_left
          (fun (params, env) (v, ty) ->
            let v', env = rename_binder state env v in
            ((v', ty) :: params, env))
          ([], env) lam.lam_params
      in
      {
        e with
        desc =
          CLambda
            {
              lam with
              lam_params = List.rev params;
              lam_body = clone body_env lam.lam_body;
            };
      }
  | CFor (binder, iter, body) ->
      let iter = clone env iter in
      let loop_var, body_env = rename_binder state env binder.loop_var in
      let body = clone body_env body in
      { e with desc = CFor ({ binder with loop_var }, iter, body) }
  | CAssign (v, rhs) ->
      { e with desc = CAssign (rename_existing_var env v, clone env rhs) }
  | CDup (v, ty, body) ->
      { e with desc = CDup (rename_existing_var env v, ty, clone env body) }
  | CDrop (v, ty, body) ->
      { e with desc = CDrop (rename_existing_var env v, ty, clone env body) }
  | CMatch (scrut, tree) ->
      { e with desc = CMatch (clone env scrut, clone_ctree state env tree) }
  | CTailrecLoop loop ->
      let loop =
        match loop with
        | TailrecUnmanagedLoop l ->
            let params, body_env = rename_params state env l.tul_params in
            TailrecUnmanagedLoop
              {
                l with
                tul_params = params;
                tul_body = clone body_env l.tul_body;
              }
        | TailrecListSpreadLoop l ->
            let params, env = rename_params state env l.tls_params in
            let tls_list_param, env =
              let cp_name, env =
                rename_binder state env l.tls_list_param.cp_name
              in
              ({ l.tls_list_param with cp_name }, env)
            in
            let tls_cursor_var, env =
              rename_binder state env l.tls_cursor_var
            in
            TailrecListSpreadLoop
              {
                l with
                tls_params = params;
                tls_list_param;
                tls_cursor_var;
                tls_body = clone env l.tls_body;
              }
      in
      { e with desc = CTailrecLoop loop }
  | CConcurrent cb ->
      let bindings, body_env =
        List.fold_left
          (fun (bindings, env_for_body) b ->
            let cb_var, env_for_body =
              rename_binder state env_for_body b.cb_var
            in
            ( { b with cb_var; cb_rhs = clone env b.cb_rhs } :: bindings,
              env_for_body ))
          ([], env) cb.conc_bindings
      in
      {
        e with
        desc =
          CConcurrent
            {
              cb with
              conc_bindings = List.rev bindings;
              conc_body = clone body_env cb.conc_body;
              conc_timeout = Option.map (clone env) cb.conc_timeout;
            };
      }
  | CConcurrentFor cf ->
      let iter = clone env cf.cf_iter in
      let cf_var, body_env = rename_binder state env cf.cf_var in
      {
        e with
        desc =
          CConcurrentFor
            {
              cf with
              cf_var;
              cf_iter = iter;
              cf_body = clone body_env cf.cf_body;
              cf_timeout = Option.map (clone env) cf.cf_timeout;
            };
      }
  | CListHandoff h ->
      let source = clone env h.lh_source in
      let capacity = clone env h.lh_capacity in
      let lh_source_var, env = rename_binder state env h.lh_source_var in
      let lh_result_var, env = rename_binder state env h.lh_result_var in
      let lh_len_var, env = rename_binder state env h.lh_len_var in
      let lh_out_var, env = rename_binder state env h.lh_out_var in
      {
        e with
        desc =
          CListHandoff
            {
              h with
              lh_source = source;
              lh_capacity = capacity;
              lh_source_var;
              lh_result_var;
              lh_len_var;
              lh_out_var;
              lh_body = clone env h.lh_body;
            };
      }
  | _ -> map_children (clone env) e

let arg_is_existing_binding arg =
  match arg.desc with CVar _ -> true | _ -> false

type prepared_arg_binding = {
  param : core_param;
  binding : inline_arg_binding;
  arg : core;
}

let prepare_args state params arg_bindings args =
  let rec loop env bindings params arg_bindings args =
    match (params, arg_bindings, args) with
    | [], [], [] -> Some (env, List.rev bindings)
    | p :: params, binding :: arg_bindings, arg :: args -> (
        match (binding, arg.desc) with
        | Substitute_existing_var, CVar actual ->
            loop ((p.cp_name, actual) :: env) bindings params arg_bindings args
        | Substitute_existing_var, _ ->
            let cp_name, env = rename_binder state env p.cp_name in
            let param = { p with cp_name } in
            loop env
              ({ param; binding = Own_binding; arg } :: bindings)
              params arg_bindings args
        | _ ->
            let cp_name, env = rename_binder state env p.cp_name in
            let param = { p with cp_name } in
            loop env
              ({ param; binding; arg } :: bindings)
              params arg_bindings args)
    | _ -> None
  in
  loop [] [] params arg_bindings args

let wrap_args ~loc bindings body =
  List.fold_right
    (fun { param = p; binding; arg } acc ->
      (* Borrowing existing variables avoids retain/read/release around hot
         read-only calls. Owned bindings preserve single evaluation and provide
         a lifetime covering the cloned body when substitution is not legal. *)
      if binding = Borrow_existing_var && arg_is_existing_binding arg then
        mk ~loc ~ty:acc.ty
          (CBorrowLet
             ( { borrow_var = p.cp_name; borrow_ty = p.cp_ty; borrow_rhs = arg },
               acc ))
      else
        mk ~loc ~ty:acc.ty
          (CLet
             ( {
                 bind_var = p.cp_name;
                 bind_mut = false;
                 bind_ty = p.cp_ty;
                 bind_rhs = arg;
               },
               acc )))
    bindings body

let expand_call state target args loc =
  if
    List.length target.params <> List.length args
    || List.length target.arg_bindings <> List.length args
  then None
  else
    match prepare_args state target.params target.arg_bindings args with
    | Some (env, bindings) ->
        let body = clone_expr state env target.body in
        Some (wrap_args ~loc bindings body)
    | None -> None

let rewrite_expr targets e =
  let state = { next_id = 0 } in
  let rec rewrite e =
    let e = map_children rewrite e in
    match e.desc with
    | CCall (CKUser (_, Some def_id), _, args) -> (
        match Hashtbl.find_opt targets def_id with
        | Some target -> (
            match expand_call state target args e.loc with
            | Some expanded -> expanded
            | None -> e)
        | None -> e)
    | _ -> e
  in
  rewrite e

let rewrite_func targets (f : core_func) : core_func =
  if Hashtbl.mem targets f.cf_def_id || compiler_owned_module f.cf_module then f
  else { f with cf_body = Option.map (rewrite_expr targets) f.cf_body }

let rewrite_decl targets d =
  let rec rewrite d =
    let desc =
      match d.cd_desc with
      | CDFunc f -> CDFunc (rewrite_func targets f)
      | CDImpl impl ->
          CDImpl
            {
              impl with
              ci_methods = List.map (rewrite_func targets) impl.ci_methods;
            }
      | CDPrivate inner -> CDPrivate (rewrite inner)
      | other -> other
    in
    { d with cd_desc = desc }
  in
  rewrite d

let rewrite_program (prog : core_program) : core_program =
  let targets = collect_targets prog in
  if Hashtbl.length targets = 0 then prog
  else List.map (rewrite_decl targets) prog
