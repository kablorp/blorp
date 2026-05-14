--- AST ---
FUNC: greet -> TYPE: String
  Params:
    PARAM: name : TYPE: String
  Body:
    BLOCK:
      CALL:
  Callee:
          IDENT: add
  Args:
          CALL:
  Callee:
              IDENT: add
  Args:
              STRING: "Hello, "
              IDENT: name
          STRING: "!"
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "greet")
    (params
      (param (name "name") (type (named "String"))))
    (return_type (named "String"))
    (body (block
        (call
          (callee (ident "add"))
          (args
            (call
              (callee (ident "add"))
              (args
                (literal_string "Hello, ")
                (ident "name" :type (named "String"))))
            (literal_string "!")))))))
