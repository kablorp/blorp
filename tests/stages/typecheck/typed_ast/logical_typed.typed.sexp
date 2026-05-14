--- AST ---
FUNC: in_range -> TYPE: Bool
  Params:
    PARAM: x : TYPE: Int
    PARAM: lo : TYPE: Int
    PARAM: hi : TYPE: Int
  Body:
    BLOCK:
      LOGICAL: and
        CALL:
  Callee:
            IDENT: ge
  Args:
            IDENT: x
            IDENT: lo
        CALL:
  Callee:
            IDENT: le
  Args:
            IDENT: x
            IDENT: hi
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "in_range")
    (params
      (param (name "x") (type (named "Int")))
      (param (name "lo") (type (named "Int")))
      (param (name "hi") (type (named "Int"))))
    (return_type (named "Bool"))
    (body (block
        (logical and
          (call
            (callee (ident "ge"))
            (args
              (ident "x" :type (named "Int"))
              (ident "lo" :type (named "Int"))))
          (call
            (callee (ident "le"))
            (args
              (ident "x" :type (named "Int"))
              (ident "hi" :type (named "Int")))))))))
