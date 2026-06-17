(** Shared policy for top-level initializer work.

    Immutable globals may be computed by CTFE. Mutable globals must not hide
    runtime startup work before [main]. Keep this analysis centralized so the
    typechecker and CTFE rewrite agree on which source forms require compile-time
    evaluation. *)

open Ast

type startup_work =
  | StartupCall of { call_name : string; call_loc : loc }
  | StartupSubscript of { subscript_loc : loc }

let resolved_call_is_constructor = function
  | Some { call_target = CallDirect { origin = CallableConstructor _; _ }; _ }
    ->
      true
  | _ -> false

let source_call_name_for_diagnostic callee resolved =
  match resolved with
  | Some { call_target = CallDirect { source_name; _ }; _ } ->
      Purity_analysis.source_call_name source_name
  | Some { call_target = CallTraitMethod { method_name; _ }; _ } ->
      Purity_analysis.source_call_name method_name
  | Some { call_target = CallClosure _; _ } -> (
      match callee.expr_desc with
      | EIdent name -> Purity_analysis.source_call_name name
      | EFieldAccess (_, name) -> name
      | _ -> "<expression>")
  | None -> (
      match callee.expr_desc with
      | EIdent name -> Purity_analysis.source_call_name name
      | EFieldAccess (_, name) -> name
      | _ -> "<expression>")

(* Subscript_desugar runs before typecheck and currently rewrites source
   subscripts to ordinary helper calls without preserving a source-syntax tag.
   Keep these helper names isolated so diagnostics can report source-level
   subscript failures instead of exposing the helper calls. *)
let is_subscript_desugar_call_name = function
  | "checked_get" | "checked_slice" | "tensor_peel" | "matrix_checked_get"
  | "tensor3_checked_get" | "tensor4_checked_get" | "tensor5_checked_get" ->
      true
  | _ -> false

let resolved_call_is_subscript_desugar resolved =
  match resolved with
  | Some { call_target = CallDirect { source_name; _ }; _ } ->
      is_subscript_desugar_call_name
        (Purity_analysis.source_call_name source_name)
  | Some { call_target = CallTraitMethod { method_name; _ }; _ } ->
      is_subscript_desugar_call_name
        (Purity_analysis.source_call_name method_name)
  | Some { call_target = CallClosure _; _ } | None -> false

let collect_startup_work (expr : expr) : startup_work list =
  let rec walk expr =
    match expr.expr_desc with
    | ELambda _ | EFuncDecl _ -> []
    | ECall (callee, args) ->
        let resolved = expr_resolved_call expr in
        let nested = List.concat_map walk (callee :: args) in
        if resolved_call_is_constructor resolved then nested
        else if resolved_call_is_subscript_desugar resolved then
          StartupSubscript { subscript_loc = expr.expr_loc } :: nested
        else
          StartupCall
            {
              call_name = source_call_name_for_diagnostic callee resolved;
              call_loc = expr.expr_loc;
            }
          :: nested
    | _ -> List.concat_map walk (expr_children expr)
  in
  walk expr

let requires_compile_time_evaluation expr = collect_startup_work expr <> []
