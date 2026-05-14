(program
  (function
    (name "countdown")
    (params
      (param (name "n") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (var_decl (mutable #t) (name "x") (type (named "Int"))
          (value (ident "n")))
        (while
          (condition (call
            (callee (ident "gt"))
            (args
              (ident "x")
              (literal_int 0))))
          (body (block
            (assign (name "x")
              (value (call
                (callee (ident "sub"))
                (args
                  (ident "x")
                  (literal_int 1))))))))
        (ident "x")))))
