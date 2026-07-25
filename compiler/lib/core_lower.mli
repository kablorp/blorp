(** Lowering from typed AST to Core IR.

    Only the declaration and program entry points needed by the compatibility
    pipeline are public. All helper functions
    ([lower_param], [lower_block], [lower_tuple_destruct], [lower_func],
    [lower_var], [lower_impl], [lower_trait], [lower_trait_method],
    [wrap_body_with_pattern_params], and the fresh-name counters) are
    intentionally hidden — they're implementation details of the two
    public entry points and may change without notice.

    {1 Invariants}

    - The public [lower_typed_*] entrypoints are the compatibility lowering
      boundary.
      Their arguments are constructed through [Typed_ast], so missing
      [expr_type] and inference metavariables are rejected before lowering
      starts.

    - Production lowering resets internal fresh-name counters before this
      phase enters. Direct test callers that need deterministic fresh names
      should reset the surrounding session before lowering. *)

val lower_typed_decl : Typed_ast.decl -> Core.core_decl
(** Lower a validated typed top-level declaration to Core. *)

val lower_typed_program : Typed_ast.program -> Core.core_program
(** Lower a validated typed program to Core. *)
