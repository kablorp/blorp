(program
  (type_decl
    (name "Option")
    (type_params "T")
    (variants
      (variant (name "Some") (fields (named "T")))
      (variant (name "None"))))
  (function
    (name "get_or_default")
    (params
      (param (name "opt") (type (named "Option" (args (named "Int")))))
      (param (name "default") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (match
          (scrutinee (ident "opt"))
          (cases
            (case
              (pattern (call
                (callee (ident "Some"))
                (args
                  (ident "x"))))
              (body (ident "x")))
            (case
              (pattern (ident "None"))
              (body (ident "default")))))))))
