(program
  (function
    (name "factorial")
    (tailrec #t)
    (params
      (param (name "n") (type (named "Int")))
      (param (name "acc") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (if
          (condition (call
            (callee (ident "le"))
            (args
              (ident "n")
              (literal_int 1))))
          (then (block
            (ident "acc")))
          (else (block
            (call
              (callee (ident "factorial"))
              (args
                (call
                  (callee (ident "sub"))
                  (args
                    (ident "n")
                    (literal_int 1)))
                (call
                  (callee (ident "mul"))
                  (args
                    (ident "n")
                    (ident "acc"))))))))))))
