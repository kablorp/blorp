--- AST ---
FUNC: count_down -> TYPE: Int
  Params:
    PARAM: n : TYPE: Int
  Body:
    BLOCK:
      VAR_DECL: x (mutable: 1) : TYPE: Int
        IDENT: n
      WHILE:
  Condition:
          CALL:
  Callee:
              IDENT: gt
  Args:
              IDENT: x
              INT: 0
  Body:
          BLOCK:
            ASSIGN: x
              CALL:
  Callee:
                  IDENT: sub
  Args:
                  IDENT: x
                  INT: 1
      IDENT: x
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "count_down")
    (params
      (param (name "n") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (var_decl (mutable #t) (name "x") (type (named "Int"))
          (value (ident "n" :type (named "Int"))))
        (while
          (condition (call
            (callee (ident "gt"))
            (args
              (ident "x" :type (named "Int"))
              (literal_int 0))))
          (body (block
            (assign (name "x")
              (value (call
                (callee (ident "sub"))
                (args
                  (ident "x" :type (named "Int"))
                  (literal_int 1))))))))
        (ident "x" :type (named "Int"))))))
