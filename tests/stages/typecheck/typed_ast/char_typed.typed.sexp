--- AST ---
FUNC: upper -> TYPE: Char
  Params:
    PARAM: c : TYPE: Char
  Body:
    BLOCK:
      IF:
  Condition:
          LOGICAL: and
            CALL:
  Callee:
                IDENT: ge
  Args:
                IDENT: c
                CHAR: U+0061
            CALL:
  Callee:
                IDENT: le
  Args:
                IDENT: c
                CHAR: U+007A
  Then:
          BLOCK:
            CALL:
  Callee:
                IDENT: char_from_int
  Args:
                CALL:
  Callee:
                    IDENT: sub
  Args:
                    CALL:
  Callee:
                        IDENT: char_to_int
  Args:
                        IDENT: c
                    INT: 32
  Else:
          BLOCK:
            IDENT: c
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "upper")
    (params
      (param (name "c") (type (named "Char"))))
    (return_type (named "Char"))
    (body (block
        (if
          (condition (logical and
            (call
              (callee (ident "ge"))
              (args
                (ident "c" :type (named "Char"))
                (literal_char 97)))
            (call
              (callee (ident "le"))
              (args
                (ident "c" :type (named "Char"))
                (literal_char 122)))))
          (then (block
            (call
              (callee (ident "char_from_int"))
              (args
                (call
                  (callee (ident "sub"))
                  (args
                    (call
                      (callee (ident "char_to_int"))
                      (args
                        (ident "c")))
                    (literal_int 32)))))))
          (else (block
            (ident "c" :type (named "Char")))))))))
