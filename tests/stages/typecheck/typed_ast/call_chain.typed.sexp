--- AST ---
FUNC: square -> TYPE: Int
  Params:
    PARAM: x : TYPE: Int
  Body:
    BLOCK:
      CALL:
  Callee:
          IDENT: mul
  Args:
          IDENT: x
          IDENT: x
FUNC: sum_squares -> TYPE: Int
  Params:
    PARAM: a : TYPE: Int
    PARAM: b : TYPE: Int
  Body:
    BLOCK:
      CALL:
  Callee:
          IDENT: add
  Args:
          CALL:
  Callee:
              IDENT: square
  Args:
              IDENT: a
          CALL:
  Callee:
              IDENT: square
  Args:
              IDENT: b
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "square")
    (params
      (param (name "x") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (call
          (callee (ident "mul"))
          (args
            (ident "x" :type (named "Int"))
            (ident "x" :type (named "Int")))))))
  (function
    (name "sum_squares")
    (params
      (param (name "a") (type (named "Int")))
      (param (name "b") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (call
          (callee (ident "add"))
          (args
            (call
              (callee (ident "square"))
              (args
                (ident "a" :type (named "Int"))))
            (call
              (callee (ident "square"))
              (args
                (ident "b" :type (named "Int"))))))))))
