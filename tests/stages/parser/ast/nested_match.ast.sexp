(program
  (type_decl
    (name "Option")
    (type_params "T")
    (variants
      (variant (name "Some") (fields (named "T")))
      (variant (name "None"))))
  (function
    (name "flatten")
    (params
      (param (name "opt") (type (named "Option" (args (named "Option" (args (named "Int"))))))))
    (return_type (named "Option" (args (named "Int"))))
    (body (block
        (match
          (scrutinee (ident "opt"))
          (cases
            (case
              (pattern (call
                (callee (ident "Some"))
                (args
                  (ident "inner"))))
              (body (ident "inner")))
            (case
              (pattern (ident "None"))
              (body (ident "None")))))))))
