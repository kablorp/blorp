(program
  (function
    (name "double")
    (params
      (param (name "x") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (call
          (callee (ident "mul"))
          (args
            (ident "x")
            (literal_int 2)))))))
