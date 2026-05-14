--- AST ---
FUNC: sum_list -> TYPE: Int
  Params:
    PARAM: nums : TYPE: List[TYPE: Int]
  Body:
    BLOCK:
      VAR_DECL: total (mutable: 1) : TYPE: Int
        INT: 0
      FOR n IN:
  Iterable:
          IDENT: nums
  Body:
          BLOCK:
            ASSIGN: total
              CALL:
  Callee:
                  IDENT: add
  Args:
                  IDENT: total
                  IDENT: n
      IDENT: total
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "sum_list")
    (params
      (param (name "nums") (type (named "List" (args (named "Int"))))))
    (return_type (named "Int"))
    (body (block
        (var_decl (mutable #t) (name "total") (type (named "Int"))
          (value (literal_int 0 :type (named "Int"))))
        (for
          (var "n")
          (iterable (ident "nums" :type (named "List" (args (named "Int")))))
          (body (block
            (assign (name "total")
              (value (call
                (callee (ident "add"))
                (args
                  (ident "total" :type (named "Int"))
                  (ident "n" :type (named "Int")))))))))
        (ident "total" :type (named "Int"))))))
