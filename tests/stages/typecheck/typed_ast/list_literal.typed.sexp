--- AST ---
FUNC: make_list -> TYPE: List[TYPE: Int]
  Params:
  Body:
    BLOCK:
      LIST_LITERAL: [INT: 1, INT: 2, INT: 3]
--- Analysis ---
Analysis succeeded.
Type checking succeeded.
(program
  (function
    (name "make_list")
    (params)
    (return_type (named "List" (args (named "Int"))))
    (body (block
        (list_literal
          (literal_int 1)
          (literal_int 2)
          (literal_int 3))))))
