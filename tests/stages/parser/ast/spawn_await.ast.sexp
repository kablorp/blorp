(program
  (function
    (name "async_compute")
    (params
      (param (name "x") (type (named "Int"))))
    (return_type (named "Int"))
    (body (block
        (assign (name "f")
          (value (spawn (call
              (callee (ident "compute"))
              (args
                (ident "x"))))))
        (await (ident "f"))))))
