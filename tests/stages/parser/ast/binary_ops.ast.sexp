(program
  (function
    (name "compute")
    (params
      (param (name "a") (type (named "Int")))
      (param (name "b") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (call
          (callee (ident "sub"))
          (args
            (call
              (callee (ident "add"))
              (args
                (ident "a")
                (call
                  (callee (ident "mul"))
                  (args
                    (ident "b")
                    (literal_int 2)))))
            (call
              (callee (ident "div"))
              (args
                (ident "a")
                (ident "b")))))))))
