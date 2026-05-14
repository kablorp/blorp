--- AST ---
FUNC: negate -> TYPE: Int
  Params:
    PARAM: x : TYPE: Int
  Body:
    BLOCK:
      CALL:
  Callee:
          IDENT: sub
  Args:
          INT: 0
          IDENT: x
FUNC: toggle -> TYPE: Bool
  Params:
    PARAM: b : TYPE: Bool
  Body:
    BLOCK:
      CALL:
  Callee:
          IDENT: not
  Args:
          IDENT: b
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "negate")
    (params
      (param (name "x") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (call
          (callee (ident "sub"))
          (args
            (literal_int 0)
            (ident "x" :type (named "Int")))))))
  (function
    (name "toggle")
    (params
      (param (name "b") (type (named "Bool"))))
    (return_type (named "Bool"))
    (body (block
        (call
          (callee (ident "not"))
          (args
            (ident "b" :type (named "Bool"))))))))
