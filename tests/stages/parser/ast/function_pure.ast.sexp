(program
  (function
    (name "add")
    (pure #t)
    (params
      (param (name "x") (type (named "Int")))
      (param (name "y") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (call
          (callee (ident "add"))
          (args
            (ident "x")
            (ident "y")))))))
