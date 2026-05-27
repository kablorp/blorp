(** Expression Type Inference for blorp Type Checker

    Implements type inference for all expression forms in the blorp language.
    Uses bidirectional type inference where possible. *)

open Ast

type 'a infer_result = ('a, compiler_error) Result.t
(** Inference result *)

type infer_ctx
(** Inference context *)

val make_ctx :
  ?module_aliases:(string * string) list ->
  ?allow_debug_only_calls:bool ->
  ?rigid_type_params:string list ->
  Env.env ->
  infer_ctx
(** Create an inference context from an environment *)

val infer_expr : infer_ctx -> expr -> (type_expr * expr) infer_result
(** Infer the type of an expression, returning the type and rewritten AST *)

val infer_expr_with_annotated_expected :
  infer_ctx -> type_expr -> expr -> (type_expr * expr) infer_result
(** Infer an expression against an explicit annotation. Annotated expected
    context is stronger than ordinary bidirectional context: it rejects literals
    that cannot construct the annotated type instead of falling back to
    shape-based inference. *)

val infer_expr_with_return_annotation :
  infer_ctx -> type_expr -> expr -> (type_expr * expr) infer_result
(** Infer a function body against an explicit return annotation. Return
    annotations can guide nested literal inference when doing so is sound for
    generic functions; otherwise the body is inferred without ambient expected
    context and the caller performs the final return-type compatibility check. *)

val type_contains_resource : infer_ctx -> type_expr -> bool
(** True when the type is or contains a resource type in the current
    environment. *)

val type_contains_one_shot_stream : Env.env -> type_expr -> bool
(** True when the type is or contains a Stream/FallibleStream cursor in the
    current environment. Function values returning streams are producer values,
    not stream cursor state, and are not considered containing streams. *)

val type_contains_one_shot_stream_function_carrier :
  Env.env -> type_expr -> bool
(** True when a function type inside this type accepts or returns a one-shot
    stream hidden in an ordinary carrier, such as [() -> Option[Stream[Int]]].
    Direct producers such as [() -> Stream[Int]] remain ordinary function
    values and return [false]. *)

val type_is_one_shot_stream : Env.env -> type_expr -> bool
(** True when the type is directly a Stream/FallibleStream cursor in the current
    environment, after alias normalization. *)

val type_contains_resource_source : Env.env -> type_expr -> bool
(** True when the type is or contains a ResourceSource cursor in the current
    environment. Function values returning resource sources are producer values,
    not source cursor state, and are not considered containing sources. *)

val type_contains_resource_source_function_carrier :
  Env.env -> type_expr -> bool
(** True when a function type inside this type accepts or returns a
    ResourceSource hidden in an ordinary carrier, such as
    [() -> Option[ResourceSource[R, E]]]. Direct producers such as
    [() -> ResourceSource[R, E]] remain ordinary function values and return
    [false]. *)

val type_is_resource_source : Env.env -> type_expr -> bool
(** True when the type is directly a ResourceSource cursor in the current
    environment, after alias normalization. *)

val inferred_binding_type : is_mutable:bool -> type_expr -> type_expr
(** Convert an inferred initializer type into the binding type stored for an
    unannotated declaration. Mutable bindings widen singleton integer
    refinements to their runtime value type because reassignment must not be
    constrained to the initializer's exact literal. *)

val annotate_inferred_binding_value :
  is_mutable:bool -> expr -> type_expr -> expr
(** Preserve both the semantic initializer type and the widened binding value
    type on an inferred unannotated binding initializer. *)

val zonk_expr : expr -> expr
(** Walk a typed expression tree and resolve every [TyMeta] annotation to
    its binding via [Types.zonk_type]. Called at end-of-body so downstream
    passes see concrete types only. *)
