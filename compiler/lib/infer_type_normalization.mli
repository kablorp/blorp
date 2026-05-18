(** Inference-time type normalization.

    This is not source annotation resolution. It is the explicit boundary for
    normalizing already-inferred or signature-derived types before compatibility
    checks, overload filtering, callee dispatch, and dimension extraction. *)

type purpose =
  | SubstitutionConflictComparison
  | ArgumentCompatibility
  | UfcsCandidateFiltering
  | CalleeDispatch
  | LambdaExpectedFunction
  | QuestionBindErrorCompatibility
  | VariadicDimensionExtraction

type context

type normalized_type = private {
  purpose : purpose;
  source : Ast.type_expr;
  normalized : Ast.type_expr;
}

val make_context : env:Env.env -> unit -> context
val normalize : context -> purpose -> Ast.type_expr -> normalized_type
val canonical : context -> purpose -> Ast.type_expr -> Ast.type_expr
val purpose : normalized_type -> purpose
val source : normalized_type -> Ast.type_expr
val normalized : normalized_type -> Ast.type_expr
