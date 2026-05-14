(program
  (function
    (name "compare")
    (params
      (param (name "a") (type (named "Int")))
      (param (name "b") (type (named "Int"))))
    (return_type (named "Bool"))
    (body (block
        (logical or
          (logical and
            (call
              (callee (ident "lt"))
              (args
                (ident "a")
                (ident "b")))
            (call
              (callee (ident "gt"))
              (args
                (ident "b")
                (literal_int 0))))
          (call
            (callee (ident "eq"))
            (args
              (ident "a")
              (ident "b"))))))))
