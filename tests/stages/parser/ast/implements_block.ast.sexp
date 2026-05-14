(program
  (trait_decl (name "Show") (functions "show"))
  (implements (trait "Show") (for_type (named "Int"))
    (body (block
      (function
        (name "show")
        (params
          (param (name "x") (type (named "Int"))))
        (return_type (named "String"))
        (body (block
            (call
              (callee (ident "int_to_string"))
              (args
                (ident "x"))))))))))
