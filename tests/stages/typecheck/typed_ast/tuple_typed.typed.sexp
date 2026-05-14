--- AST ---
FUNC: make_pair -> TYPE: Tuple[TYPE: Int, TYPE: Int]
  Params:
    PARAM: x : TYPE: Int
    PARAM: y : TYPE: Int
  Body:
    BLOCK:
      TUPLE: (IDENT: x, IDENT: y)
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "make_pair")
    (params
      (param (name "x") (type (named "Int")))
      (param (name "y") (type (named "Int"))))
    (return_type (named "Tuple" (args (named "Int") (named "Int"))))
    (body (block
        (tuple
          (ident "x" :type (named "Int"))
          (ident "y" :type (named "Int")))))))
