--- AST ---
TYPE_DECL: Option[T]
  VARIANT: Some(TYPE: T)
  VARIANT: None
FUNC: map[T, U] -> TYPE: Option[TYPE: U]
  Params:
    PARAM: opt : TYPE: Option[TYPE: T]
    PARAM: f : FUNC_TYPE: (TYPE: T) -> TYPE: U
  Body:
    BLOCK:
      MATCH:
  Condition:
          IDENT: opt
  Cases:
          CASE:
  Pattern:
              CALL:
  Callee:
                  IDENT: Some
  Args:
                  IDENT: x
  Body:
              CALL:
  Callee:
                  IDENT: Some
  Args:
                  CALL:
  Callee:
                      IDENT: f
  Args:
                      IDENT: x
          CASE:
  Pattern:
              IDENT: None
  Body:
              IDENT: None
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (type_decl
    (name "Option")
    (type_params "T")
    (variants
      (variant (name "Some") (fields (named "T")))
      (variant (name "None"))))
  (function
    (name "map")
    (type_params "T" "U")
    (params
      (param (name "opt") (type (named "Option" (args (named "T")))))
      (param (name "f") (type (func_type (params (named "T")) (return (named "U"))))))
    (return_type (named "Option" (args (named "U"))))
    (body (block
        (match
          (scrutinee (ident "opt" :type (named "Option" (args (named "T")))))
          (cases
            (case
              (pattern (call
                (callee (ident "Some"))
                (args
                  (ident "x"))))
              (body (call
                (callee (ident "Some"))
                (args
                  (call
                    (callee (ident "f"))
                    (args
                      (ident "x" :type (named "T"))))))))
            (case
              (pattern (ident "None"))
              (body (ident "None")))))))))
