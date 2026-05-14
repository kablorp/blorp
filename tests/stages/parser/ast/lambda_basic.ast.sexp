(program
  (function
    (name "apply")
    (params
      (param (name "f") (type (func_type (params (named "Int")) (return (named "Int")))))
      (param (name "x") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (call
          (callee (ident "f"))
          (args
            (ident "x")))))))
