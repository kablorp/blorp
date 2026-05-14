--- AST ---
FUNC: circle_area -> TYPE: Float
  Params:
    PARAM: r : TYPE: Float
  Body:
    BLOCK:
      CALL:
  Callee:
          IDENT: mul
  Args:
          CALL:
  Callee:
              IDENT: mul
  Args:
              FLOAT: 3.141590
              IDENT: r
          IDENT: r
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "circle_area")
    (params
      (param (name "r") (type (named "Float"))))
    (return_type (named "Float"))
    (body (block
        (call
          (callee (ident "mul"))
          (args
            (call
              (callee (ident "mul"))
              (args
                (literal_float 3.141590)
                (ident "r" :type (named "Float"))))
            (ident "r" :type (named "Float"))))))))
