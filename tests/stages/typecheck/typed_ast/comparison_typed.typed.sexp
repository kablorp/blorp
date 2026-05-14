--- AST ---
FUNC: is_positive -> TYPE: Bool
  Params:
    PARAM: x : TYPE: Int
  Body:
    BLOCK:
      CALL:
  Callee:
          IDENT: gt
  Args:
          IDENT: x
          INT: 0
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "is_positive")
    (params
      (param (name "x") (type (named "Int"))))
    (return_type (named "Bool"))
    (body (block
        (call
          (callee (ident "gt"))
          (args
            (ident "x" :type (named "Int"))
            (literal_int 0)))))))
