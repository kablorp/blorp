(** Pattern-match decision-tree emission for the C backend — extracted
    from [core_emit.ml] in Phase 5.1 step 3.

    [Core_match] compiles every [match] expression into a decision
    tree ([ctree]); [assign] walks that tree in expression context
    (each leaf stores its body into a [result_name] variable) and
    [stmt] walks it in statement context (each leaf runs as a
    statement). The two are mutually recursive through nested matches.

    [emit_expr], [emit_stmt], [emit_ctree_assign] (self), and
    [emit_ctree_stmt] (self) are threaded as labeled callbacks so
    this module doesn't live in [core_emit.ml]'s rec chain. One
    indirect call per dispatch — negligible vs the emit work. *)

open Core
open Core_emit_context
open Core_emit_util
open Codegen_types

(** Expression-context walk: each leaf's body assigns to [result_name].

    Only [emit_expr] (for leaf bodies) and [emit_ctree_assign] (self,
    for nested tree dispatch) are used — the statement-context walker
    is a disjoint entry point reached only from [emit_stmt]'s [CMatch]
    branch, so this function never falls through to [stmt]. *)
let assign ~(emit_expr : Core_emit_context.t -> core -> unit)
    ~(emit_ctree_assign :
       Core_emit_context.t -> string -> Ast.type_expr -> string -> ctree -> unit)
    (ctx : Core_emit_context.t) (scrut_name : string) (scrut_ty : Ast.type_expr)
    (result_name : string) (tree : ctree) : unit =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let var_types = collect_var_types ct_body in
      List.iter
        (fun (v, acc) ->
          if not (Hashtbl.mem ctx.constructor_names v.vname) then begin
            let var_ty = find_var_type v.vname var_types in
            let acc_c = render_accessor_typed ctx scrut_name scrut_ty acc in
            emit ctx
              (unbox_decl_for_accessor_str ctx
                 (escape_c_ident (Var.to_c_name v))
                 ~scrut_ty ~accessor:acc ~source:acc_c var_ty);
            emit ctx " "
          end)
        ct_bindings;
      emit ctx (Printf.sprintf "%s = " result_name);
      emit_expr ctx ct_body;
      emit ctx "; "
  | CTFail ->
      emit ctx "fprintf(stderr, \"blorp: non-exhaustive match\\n\"); abort(); "
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } -> (
      let acc_c = render_accessor_typed ctx scrut_name scrut_ty cts_scrut in
      List.iteri
        (fun i (ctor, subtree) ->
          let test = tag_test_str ctx scrut_ty cts_scrut acc_c ctor in
          if i = 0 then emit ctx (Printf.sprintf "if (%s) { " test)
          else emit ctx (Printf.sprintf "} else if (%s) { " test);
          emit_ctree_assign ctx scrut_name scrut_ty result_name subtree)
        cts_cases;
      match cts_default with
      | Some d ->
          emit ctx "} else { ";
          emit_ctree_assign ctx scrut_name scrut_ty result_name d;
          emit ctx "} "
      | None -> emit ctx "} ")
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      let acc_c = render_accessor_typed ctx scrut_name scrut_ty ctl_scrut in
      List.iteri
        (fun i (lit, subtree) ->
          if i = 0 then begin
            emit ctx "if (";
            emit_lit_cmp ctx acc_c lit;
            emit ctx ") { "
          end
          else begin
            emit ctx "} else if (";
            emit_lit_cmp ctx acc_c lit;
            emit ctx ") { "
          end;
          emit_ctree_assign ctx scrut_name scrut_ty result_name subtree)
        ctl_cases;
      emit ctx "} else { ";
      emit_ctree_assign ctx scrut_name scrut_ty result_name ctl_default;
      emit ctx "} "
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    -> (
      let acc_c = render_accessor_typed ctx scrut_name scrut_ty ctl_len_scrut in
      let list_c = Printf.sprintf "((blorp_List*)%s)" acc_c in
      let all_cases =
        ctl_len_cases
        @ match ctl_len_geq with Some (n, t) -> [ (n, t) ] | None -> []
      in
      List.iteri
        (fun i (len, subtree) ->
          let is_geq = ctl_len_geq <> None && i = List.length ctl_len_cases in
          let op = if is_geq then ">=" else "==" in
          if i = 0 then
            emit ctx (Printf.sprintf "if (%s->len %s %dL) { " list_c op len)
          else
            emit ctx
              (Printf.sprintf "} else if (%s->len %s %dL) { " list_c op len);
          emit_ctree_assign ctx scrut_name scrut_ty result_name subtree)
        all_cases;
      match ctl_len_default with
      | Some d ->
          emit ctx "} else { ";
          emit_ctree_assign ctx scrut_name scrut_ty result_name d;
          emit ctx "} "
      | None -> emit ctx "} ")

(** Statement-context walk: each leaf runs its body via [emit_stmt].

    Mirror of [assign] — only [emit_stmt] and self ([emit_ctree_stmt])
    are needed; the expression-context walker isn't reachable from
    here. *)
let stmt ~(emit_stmt : Core_emit_context.t -> core -> unit)
    ~(emit_ctree_stmt :
       Core_emit_context.t -> string -> Ast.type_expr -> ctree -> unit)
    (ctx : Core_emit_context.t) (scrut_name : string) (scrut_ty : Ast.type_expr)
    (tree : ctree) : unit =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let var_types = collect_var_types ct_body in
      List.iter
        (fun (v, acc) ->
          if not (Hashtbl.mem ctx.constructor_names v.vname) then begin
            let var_ty = find_var_type v.vname var_types in
            let acc_c = render_accessor_typed ctx scrut_name scrut_ty acc in
            emit_line ctx
              (unbox_decl_for_accessor_str ctx
                 (escape_c_ident (Var.to_c_name v))
                 ~scrut_ty ~accessor:acc ~source:acc_c var_ty)
          end)
        ct_bindings;
      emit_stmt ctx ct_body
  | CTFail ->
      emit_line ctx "fprintf(stderr, \"blorp: non-exhaustive match\\n\");";
      emit_line ctx "abort();"
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } -> (
      let acc_c = render_accessor_typed ctx scrut_name scrut_ty cts_scrut in
      List.iteri
        (fun i (ctor, subtree) ->
          emit_indent ctx;
          let test = tag_test_str ctx scrut_ty cts_scrut acc_c ctor in
          if i = 0 then emitln ctx (Printf.sprintf "if (%s) {" test)
          else emitln ctx (Printf.sprintf "} else if (%s) {" test);
          ctx.indent <- ctx.indent + 1;
          emit_ctree_stmt ctx scrut_name scrut_ty subtree;
          ctx.indent <- ctx.indent - 1)
        cts_cases;
      match cts_default with
      | Some d ->
          emit_indent ctx;
          emitln ctx "} else {";
          ctx.indent <- ctx.indent + 1;
          emit_ctree_stmt ctx scrut_name scrut_ty d;
          ctx.indent <- ctx.indent - 1;
          emit_indent ctx;
          emitln ctx "}"
      | None ->
          emit_indent ctx;
          emitln ctx "}")
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      let acc_c = render_accessor_typed ctx scrut_name scrut_ty ctl_scrut in
      List.iteri
        (fun i (lit, subtree) ->
          emit_indent ctx;
          if i = 0 then begin
            emit ctx "if (";
            emit_lit_cmp ctx acc_c lit;
            emitln ctx ") {"
          end
          else begin
            emit ctx "} else if (";
            emit_lit_cmp ctx acc_c lit;
            emitln ctx ") {"
          end;
          ctx.indent <- ctx.indent + 1;
          emit_ctree_stmt ctx scrut_name scrut_ty subtree;
          ctx.indent <- ctx.indent - 1)
        ctl_cases;
      emit_indent ctx;
      emitln ctx "} else {";
      ctx.indent <- ctx.indent + 1;
      emit_ctree_stmt ctx scrut_name scrut_ty ctl_default;
      ctx.indent <- ctx.indent - 1;
      emit_indent ctx;
      emitln ctx "}"
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    -> (
      let acc_c = render_accessor_typed ctx scrut_name scrut_ty ctl_len_scrut in
      let list_c = Printf.sprintf "((blorp_List*)%s)" acc_c in
      let all_cases =
        ctl_len_cases
        @ match ctl_len_geq with Some (n, t) -> [ (n, t) ] | None -> []
      in
      List.iteri
        (fun i (len, subtree) ->
          let is_geq = ctl_len_geq <> None && i = List.length ctl_len_cases in
          let op = if is_geq then ">=" else "==" in
          emit_indent ctx;
          if i = 0 then
            emitln ctx (Printf.sprintf "if (%s->len %s %dL) {" list_c op len)
          else
            emitln ctx
              (Printf.sprintf "} else if (%s->len %s %dL) {" list_c op len);
          ctx.indent <- ctx.indent + 1;
          emit_ctree_stmt ctx scrut_name scrut_ty subtree;
          ctx.indent <- ctx.indent - 1)
        all_cases;
      match ctl_len_default with
      | Some d ->
          emit_indent ctx;
          emitln ctx "} else {";
          ctx.indent <- ctx.indent + 1;
          emit_ctree_stmt ctx scrut_name scrut_ty d;
          ctx.indent <- ctx.indent - 1;
          emit_indent ctx;
          emitln ctx "}"
      | None ->
          emit_indent ctx;
          emitln ctx "}")
