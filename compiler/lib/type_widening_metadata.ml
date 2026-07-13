(** Compatibility aliases for widening metadata shared across frontend phases.

    The canonical definitions live in [Ast] because [Ast.expr] carries the
    transitional typed payload during the typed-AST migration. *)

type collection_kind = Ast.type_widening_collection_kind =
  | ListLiteral
  | VectorLiteral
  | DictLiteral
  | SetLiteral

type reason = Ast.type_widening_reason =
  | MutableBinding
  | ArgumentSlot
  | CollectionElement of collection_kind
  | BitwiseOperator
  | MethodReceiver
  | RangeProofErasure
  | TupleLiteral
  | NumericOperator of Ast.binop

type decision = Ast.type_widening_decision =
  | Keep of Ast.type_expr
  | Widen of { from_ty : Ast.type_expr; to_ty : Ast.type_expr; reason : reason }
