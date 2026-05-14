(program
  (function
    (name "max")
    (params
      (param (name "a") (type (named "Int")))
      (param (name "b") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (if
          (condition (call
            (callee (ident "gt"))
            (args
              (ident "a")
              (ident "b"))))
          (then (block
            (ident "a")))
          (else (block
            (ident "b"))))))))
