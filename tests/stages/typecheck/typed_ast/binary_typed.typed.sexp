--- AST ---
FUNC: calculate -> TYPE: Int
  Params:
    PARAM: a : TYPE: Int
    PARAM: b : TYPE: Int
  Body:
    BLOCK:
      CALL:
  Callee:
          IDENT: add
  Args:
          IDENT: a
          CALL:
  Callee:
              IDENT: mul
  Args:
              IDENT: b
              INT: 2
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "calculate")
    (params
      (param (name "a") (type (named "Int")))
      (param (name "b") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (call
          (callee (ident "add"))
          (args
            (ident "a" :type (named "Int"))
            (call
              (callee (ident "mul"))
              (args
                (ident "b" :type (named "Int"))
                (literal_int 2)))))))))
