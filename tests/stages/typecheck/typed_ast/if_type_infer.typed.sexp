--- AST ---
FUNC: abs -> TYPE: Int
  Params:
    PARAM: x : TYPE: Int
  Body:
    BLOCK:
      IF:
  Condition:
          CALL:
  Callee:
              IDENT: lt
  Args:
              IDENT: x
              INT: 0
  Then:
          BLOCK:
            CALL:
  Callee:
                IDENT: sub
  Args:
                INT: 0
                IDENT: x
  Else:
          BLOCK:
            IDENT: x
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "abs")
    (params
      (param (name "x") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (if
          (condition (call
            (callee (ident "lt"))
            (args
              (ident "x" :type (named "Int"))
              (literal_int 0))))
          (then (block
            (call
              (callee (ident "sub"))
              (args
                (literal_int 0)
                (ident "x" :type (named "Int"))))))
          (else (block
            (ident "x" :type (named "Int")))))))))
