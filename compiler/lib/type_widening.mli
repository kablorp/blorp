(** Explicit type widening decisions.

    Inference sometimes needs an ergonomic runtime slot type that is less
    precise than an expression's semantic type. A value slot keeps both facts:
    the semantic type produced by inference, and the value type used at a
    mutable/argument/operator boundary. *)

type collection_kind = Type_widening_metadata.collection_kind =
  | ListLiteral
  | VectorLiteral
  | DictLiteral
  | SetLiteral

type reason = Type_widening_metadata.reason =
  | MutableBinding
  | ArgumentSlot
  | CollectionElement of collection_kind
  | BitwiseOperator
  | MethodReceiver
  | NumericOperator of Ast.binop

type decision = Type_widening_metadata.decision =
  | Keep of Ast.type_expr
  | Widen of { from_ty : Ast.type_expr; to_ty : Ast.type_expr; reason : reason }

type value_slot

val semantic_type : value_slot -> Ast.type_expr
val value_type : value_slot -> Ast.type_expr
val decision : value_slot -> decision
val keep_slot : Ast.type_expr -> value_slot

val scalar_int_value_type : Ast.type_expr -> Ast.type_expr
(** Runtime value type for scalar integer refinements such as singleton
    integer literals and dimension ranges. Variadic dimension packs are not
    scalar values and are preserved. *)

val is_scalar_int_value_type : Ast.type_expr -> bool
(** True when [scalar_int_value_type] is the ordinary runtime [Int] type. *)

val mutable_binding_slot : Ast.type_expr -> value_slot
(** Mutable slots hold ordinary runtime values, so singleton integer
    initializers widen to [Int] while their semantic type is retained. *)

val argument_slot : param_ty:Ast.type_expr -> arg_ty:Ast.type_expr -> value_slot
(** Argument slots widen singleton integers only when the parameter is an open
    value meta or [Self]. Dimension metas keep proof precision. *)

val argument_target_slot : param_ty:Ast.type_expr -> Ast.type_expr -> value_slot
(** Arguments checked against a known parameter slot keep their semantic type
    while recording the runtime parameter value type only for known contextual
    literal narrowing. Open value metas still use ordinary singleton-to-[Int]
    widening; type-variable and dimension slots keep proof precision so the call
    checker can bind them from the argument. *)

val collection_element_slot : collection_kind -> Ast.type_expr -> value_slot
(** Collection constructors infer an element value type without rewriting the
    semantic type of the element expression. *)

val collection_element_target_slot :
  collection_kind -> target_ty:Ast.type_expr -> Ast.type_expr -> value_slot
(** Collection elements checked against a known target element type keep their
    semantic type while recording the collection value slot type. *)

val bitwise_operand_slot : Ast.type_expr -> value_slot
(** Bitwise operators accept integer value slots, including singleton integer
    literals widened to [Int]. *)

val bitwise_operand_target_slot :
  target_ty:Ast.type_expr -> Ast.type_expr -> value_slot
(** Bitwise operands checked against a known integer result type keep their
    semantic type while recording the bitwise operand value slot type. *)

val method_receiver_slot : Ast.type_expr -> value_slot
(** Trait method receiver substitution can require the receiver's value type,
    but the receiver expression keeps its semantic type. *)

val numeric_operand_slot : Ast.binop -> Ast.type_expr -> value_slot
(** Numeric value-context arithmetic deliberately lifts dimension/range proofs
    to their runtime operand type. *)

val numeric_operand_type : Ast.binop -> Ast.type_expr -> Ast.type_expr
