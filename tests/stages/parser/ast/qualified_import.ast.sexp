(program
  (import (module "std/List") (alias "L"))
  (function
    (name "double_list")
    (params
      (param (name "nums") (type (named "List" (args (named "Int"))))))
    (return_type (named "List" (args (named "Int"))))
    (body (block
        (call
          (callee (ident "map"))
          (args
            (ident "L")
            (ident "nums")
            (function
              (name "<lambda>")
              (params
                (param (name "x") (type ())))
              (return_type ())
              (body (block
                  (call
                    (callee (ident "mul"))
                    (args
                      (ident "x")
                      (literal_int 2))))))))))))
