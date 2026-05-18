(** Inference-time type normalization.

    Inference uses alias-expanded shapes for several compatibility decisions.
    Keeping those expansions behind purpose-tagged APIs makes it clear they are
    not source annotation resolution and gives later work a single place to
    preserve richer provenance. *)

type purpose =
  | SubstitutionConflictComparison
  | ArgumentCompatibility
  | UfcsCandidateFiltering
  | CalleeDispatch
  | TryErrorCompatibility
  | VariadicDimensionExtraction

type context = { env : Env.env }

type normalized_type = {
  purpose : purpose;
  source : Ast.type_expr;
  normalized : Ast.type_expr;
}

let make_context ~env () = { env }

let normalize ctx purpose source =
  { purpose; source; normalized = Env.resolve_alias ctx.env source }

let canonical ctx purpose source = (normalize ctx purpose source).normalized
let purpose normalized = normalized.purpose
let source normalized = normalized.source
let normalized normalized = normalized.normalized
