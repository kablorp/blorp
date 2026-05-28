(** Source-span helpers shared by formatter projection and legacy formatter
    tests.

    These functions answer "which source line does this AST node cover?" They
    do not render anything, so JSON projection can preserve comments without
    depending on the legacy OCaml pretty-printer. *)

open Ast

let loc_end_line loc = max loc.line loc.end_line

let rec expr_source_end_line e =
  let base = loc_end_line e.expr_loc in
  let max_exprs acc exprs =
    List.fold_left (fun acc e -> max acc (expr_source_end_line e)) acc exprs
  in
  let max_fields acc fields =
    List.fold_left
      (fun acc (_, e) -> max acc (expr_source_end_line e))
      acc fields
  in
  let max_optional_expr acc = function
    | None -> acc
    | Some e -> max acc (expr_source_end_line e)
  in
  match e.expr_desc with
  | EIdent _ | ELiteral _ | EVoid | EBreak | EContinue | EBuiltin _ -> base
  | EUnary (_, inner)
  | EAscription (inner, _)
  | EFieldAccess (inner, _)
  | EDetach inner ->
      max base (expr_source_end_line inner)
  | EBinary (_, left, right) | ERange (left, right) | ESubscript (left, right)
    ->
      max base (max (expr_source_end_line left) (expr_source_end_line right))
  | ELogical (_, left, right) ->
      max e.expr_loc.line
        (max (expr_source_end_line left) (expr_source_end_line right))
  | ECall (callee, args) ->
      max_exprs (max base (expr_source_end_line callee)) args
  | EIf (cond, then_expr, else_expr) ->
      max_optional_expr
        (max base
           (max (expr_source_end_line cond) (expr_source_end_line then_expr)))
        else_expr
  | EMatch (scrutinee, cases) ->
      List.fold_left
        (fun acc case ->
          max acc
            (max
               (loc_end_line case.case_loc)
               (expr_source_end_line case.case_body)))
        (max base (expr_source_end_line scrutinee))
        cases
  | EBlock exprs
  | EList exprs
  | EVector exprs
  | ETuple exprs
  | EDebugBlock exprs ->
      max_exprs base exprs
  | ERecord fields -> max_fields base fields
  | ERecordUpdate (source, fields) ->
      max_fields (max base (expr_source_end_line source)) fields
  | ELambda fd -> max base (func_source_end_line fd)
  | EWhile (cond, body) | EFor (_, cond, body) | EForTuple (_, cond, body) ->
      max base (max (expr_source_end_line cond) (expr_source_end_line body))
  | ELoopView view ->
      max_optional_expr
        (max base (expr_source_end_line view.loop_view_source))
        view.loop_view_size_arg
  | EAssign (_, value)
  | ECompoundAssign (_, _, value)
  | EVarDecl (_, _, value, _)
  | ETupleDestruct (_, value)
  | EQuestionBind (_, _, value) ->
      max base (expr_source_end_line value)
  | ESubscriptMulti (target, indices) ->
      max_exprs (max base (expr_source_end_line target)) indices
  | ESubscriptAssign (target, indices, value) ->
      max_exprs
        (max base
           (max (expr_source_end_line target) (expr_source_end_line value)))
        indices
  | EStringInterp (parts, _) ->
      List.fold_left
        (fun acc -> function
          | InterpLit _ -> acc
          | InterpExpr e -> max acc (expr_source_end_line e))
        base parts
  | EStringInterpRaw _ -> base
  | EConcurrent (bindings, timeout, _) ->
      max_optional_expr (max_exprs base bindings) timeout
  | EConcurrentBind (_, _, value) -> max base (expr_source_end_line value)
  | ESelect arms ->
      List.fold_left
        (fun acc arm ->
          let acc =
            match arm.select_arm_kind with
            | SelectRecv { select_channel; _ } ->
                max acc (expr_source_end_line select_channel)
            | SelectAfter timeout -> max acc (expr_source_end_line timeout)
            | SelectSealed channel -> max acc (expr_source_end_line channel)
          in
          max acc (expr_source_end_line arm.select_arm_body))
        base arms
  | EWith (binding, body) ->
      max base
        (max
           (expr_source_end_line binding.with_value)
           (expr_source_end_line body))
  | EConcurrentlyLoop (_, iterable, body, timeout, _) ->
      max_optional_expr
        (max base
           (max (expr_source_end_line iterable) (expr_source_end_line body)))
        timeout
  | EDict entries ->
      List.fold_left
        (fun acc (key, value) ->
          max acc (max (expr_source_end_line key) (expr_source_end_line value)))
        base entries
  | EFuncDecl fd -> max base (func_source_end_line fd)

and func_source_end_line fd =
  match fd.func_body with
  | FuncBodyExpr body -> expr_source_end_line body
  | FuncBuiltinBody (_, loc) -> loc_end_line loc
  | FuncForeign _ | FuncNoBody -> 0
