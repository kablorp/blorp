(program
  (function
    (name "example")
    (params)
    (return_type (named "Int"))
    (body (block
        (assign (name "x")
          (value (literal_int 10)))
        (var_decl (mutable #t) (name "y") (type (named "Int"))
          (value (literal_int 20)))
        (call
          (callee (ident "add"))
          (args
            (ident "x")
            (ident "y")))))))
