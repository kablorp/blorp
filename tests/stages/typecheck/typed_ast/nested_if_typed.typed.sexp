--- AST ---
FUNC: clamp -> TYPE: Int
  Params:
    PARAM: x : TYPE: Int
    PARAM: lo : TYPE: Int
    PARAM: hi : TYPE: Int
  Body:
    BLOCK:
      IF:
  Condition:
          CALL:
  Callee:
              IDENT: lt
  Args:
              IDENT: x
              IDENT: lo
  Then:
          BLOCK:
            IDENT: lo
  Else:
          BLOCK:
            IF:
  Condition:
                CALL:
  Callee:
                    IDENT: gt
  Args:
                    IDENT: x
                    IDENT: hi
  Then:
                BLOCK:
                  IDENT: hi
  Else:
                BLOCK:
                  IDENT: x
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "clamp")
    (params
      (param (name "x") (type (named "Int")))
      (param (name "lo") (type (named "Int")))
      (param (name "hi") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (if :type (named "Int")
          (condition (call
            (callee (ident "lt"))
            (args
              (ident "x" :type (named "Int"))
              (ident "lo" :type (named "Int")))))
          (then (block
            (ident "lo" :type (named "Int"))))
          (else (block
            (if :type (named "Int")
              (condition (call
                (callee (ident "gt"))
                (args
                  (ident "x" :type (named "Int"))
                  (ident "hi" :type (named "Int")))))
              (then (block
                (ident "hi" :type (named "Int"))))
              (else (block
                (ident "x" :type (named "Int"))))))))))))
