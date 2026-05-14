(program
  (function
    (name "sum_list")
    (params
      (param (name "nums") (type (named "List" (args (named "Int"))))))
    (return_type (named "Int"))
    (body (block
        (var_decl (mutable #t) (name "total") (type (named "Int"))
          (value (literal_int 0)))
        (for
          (var "n")
          (iterable (ident "nums"))
          (body (block
            (assign (name "total")
              (value (call
                (callee (ident "add"))
                (args
                  (ident "total")
                  (ident "n"))))))))
        (ident "total")))))
