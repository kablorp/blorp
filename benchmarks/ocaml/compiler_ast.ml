(* Compiler-shaped AST pass benchmark.
   Models repeated recursive IR rewrites over immutable tree nodes. *)

type expr =
  | ELit of int
  | EVar of int
  | EAdd of expr * expr
  | EMul of expr * expr
  | ELet of int * expr * expr
  | EIf of expr * expr * expr

let rec build_expr depth seed =
  if depth <= 0 then
    if seed mod 3 = 0 then EVar (seed mod 4096)
    else ELit ((seed * 17 + 11) mod 100000)
  else
    let next = (seed * 3) + depth in
    match depth mod 5 with
    | 0 -> EAdd (build_expr (depth - 1) next, build_expr (depth - 1) (next + 1))
    | 1 -> EMul (build_expr (depth - 1) next, build_expr (depth - 1) (next + 3))
    | 2 -> ELet (seed mod 8192, build_expr (depth - 1) next, build_expr (depth - 1) (next + 5))
    | 3 ->
        EIf
          ( build_expr (depth - 1) next,
            build_expr (depth - 2) (next + 7),
            build_expr (depth - 2) (next + 11) )
    | _ -> EAdd (build_expr (depth - 1) (next + 13), build_expr (depth - 1) (next + 17))

let rec rewrite_expr expr pass =
  match expr with
  | ELit value -> ELit ((value + (pass * 13) + 7) mod 1000003)
  | EVar id -> EVar (((id * 33) + pass + 19) mod 16384)
  | EAdd (left, right) ->
      if pass mod 7 = 0 then EAdd (rewrite_expr right pass, rewrite_expr left pass)
      else EAdd (rewrite_expr left pass, rewrite_expr right pass)
  | EMul (left, right) -> EMul (rewrite_expr left pass, rewrite_expr right pass)
  | ELet (name, value, body) ->
      ELet ((name + pass) mod 16384, rewrite_expr value pass, rewrite_expr body (pass + 1))
  | EIf (cond, then_expr, else_expr) ->
      EIf
        ( rewrite_expr cond pass,
          rewrite_expr then_expr (pass + 2),
          rewrite_expr else_expr (pass + 3) )

let rec checksum_expr expr =
  match expr with
  | ELit value -> value + 3
  | EVar id -> (id * 5) + 7
  | EAdd (left, right) -> 11 + (checksum_expr left * 3) + checksum_expr right
  | EMul (left, right) -> 17 + checksum_expr left + (checksum_expr right * 3)
  | ELet (name, value, body) -> 23 + name + checksum_expr value + (checksum_expr body * 5)
  | EIf (cond, then_expr, else_expr) ->
      31 + checksum_expr cond + (checksum_expr then_expr * 7) + checksum_expr else_expr

let run_pipeline depth passes =
  let expr = ref (build_expr depth 19) in
  let checksum = ref 0 in
  for pass = 0 to passes - 1 do
    expr := rewrite_expr !expr pass;
    if pass mod 8 = 0 then checksum := !checksum + checksum_expr !expr
  done;
  !checksum + checksum_expr !expr

let () =
  let checksum = run_pipeline 11 80 in
  Printf.printf "compiler_ast checksum: %d\n" checksum
