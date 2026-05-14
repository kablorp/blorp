(program
  (function
    (name "make_list")
    (params)
    (return_type (named "List" (args (named "Int"))))
    (body (block
        (list_literal
          (literal_int 1)
          (literal_int 2)
          (literal_int 3)
          (literal_int 4)
          (literal_int 5))))))
