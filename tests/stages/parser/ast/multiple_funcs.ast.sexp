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
            (ident "x")
            (ident "y"))))))
  (function
    (name "sub")
    (params
      (param (name "x") (type (named "Int")))
      (param (name "y") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (call
          (callee (ident "sub"))
          (args
            (ident "x")
            (ident "y"))))))
  (function
    (name "mul")
    (params
      (param (name "x") (type (named "Int")))
      (param (name "y") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (call
          (callee (ident "mul"))
          (args
            (ident "x")
            (ident "y")))))))
