(** Diagnostics shared by compile-time evaluation modules. *)

let error ?(notes = []) ?help loc message =
  {
    Ast.message;
    loc;
    phase = Ast.TypeCheck;
    kind = Ast.OtherError;
    notes;
    help;
  }

let typed_ast_error_to_error (err : Typed_ast.error) =
  let loc, message =
    match err with
    | MissingExprType { loc; context } ->
        ( loc,
          Printf.sprintf "internal CTFE error: %s missing expression type"
            context )
    | MissingExprTypeInfo { loc; context } ->
        ( loc,
          Printf.sprintf
            "internal CTFE error: %s missing structured expression type \
             metadata"
            context )
    | UnfinalizedExprType { loc; context; ty } ->
        ( loc,
          Printf.sprintf
            "internal CTFE error: %s still contains inference metavariables: %s"
            context (Types.type_to_string ty) )
    | MissingRequiredType { loc; context } ->
        (loc, Printf.sprintf "internal CTFE error: %s missing type" context)
    | UnfinalizedType { loc; context; ty } ->
        ( loc,
          Printf.sprintf
            "internal CTFE error: %s still contains inference metavariables: %s"
            context (Types.type_to_string ty) )
    | InvalidTypeInfo { loc; context; message } ->
        ( loc,
          Printf.sprintf "internal CTFE error: invalid %s: %s" context message
        )
  in
  error loc message

let unsupported loc form =
  Error
    [
      error
        ~help:
          "Use supported pure compile-time constructs here, or move this \
           computation back to runtime code."
        loc
        (Printf.sprintf "compile_time evaluator does not support %s yet" form);
    ]
