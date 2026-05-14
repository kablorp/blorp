--- AST ---
FUNC: add -> TYPE: Int
  Params:
    PARAM: x : TYPE: Int
    PARAM: y : TYPE: Int
  Body:
    BLOCK:
      CALL:
  Callee:
          IDENT: add
  Args:
          IDENT: x
          IDENT: y
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "add")
    (params
      (param (name "x") (type (named "Int")))
      (param (name "y") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (call
          (callee (ident "add"))
          (args
            (ident "x" :type (named "Int"))
            (ident "y" :type (named "Int"))))))))
