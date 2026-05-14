--- AST ---
TYPE_DECL: Option[T]
  VARIANT: Some(TYPE: T)
  VARIANT: None
FUNC: get_or_zero -> TYPE: Int
  Params:
    PARAM: opt : TYPE: Option[TYPE: Int]
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
              IDENT: x
          CASE:
  Pattern:
              IDENT: None
  Body:
              INT: 0
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
    (name "get_or_zero")
    (params
      (param (name "opt") (type (named "Option" (args (named "Int"))))))
    (return_type (named "Int"))
    (body (block
        (match
          (scrutinee (ident "opt" :type (named "Option" (args (named "Int")))))
          (cases
            (case
              (pattern (call
                (callee (ident "Some"))
                (args
                  (ident "x"))))
              (body (ident "x" :type (named "Int"))))
            (case
              (pattern (ident "None"))
              (body (literal_int 0)))))))))
