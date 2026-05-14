(program
  (function
    (name "make_pair")
    (params
      (param (name "a") (type (named "Int")))
      (param (name "b") (type (named "String"))))
    (return_type (named "Tuple" (args (named "Int") (named "String"))))
    (body (block
        (tuple
          (ident "a")
          (ident "b"))))))
