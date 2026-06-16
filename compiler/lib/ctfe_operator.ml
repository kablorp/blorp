(** Primitive operator evaluation for CTFE values. *)

open Ctfe_value
open Ctfe_value_ops

let ( >>= ) = Result.bind

let eval_int_binop loc op left right =
  expect_int loc left >>= fun l ->
  expect_int loc right >>= fun r ->
  let result =
    match op with
    | Ast.Add -> Int64.add l r
    | Ast.Sub -> Int64.sub l r
    | Ast.Mul -> Int64.mul l r
    | Ast.Div -> if r = 0L then 0L else Int64.div l r
    | Ast.Mod -> if r = 0L then 0L else Int64.rem l r
    | Ast.Lt | Ast.Gt | Ast.Le | Ast.Ge | Ast.Eq | Ast.Ne ->
        invalid_arg "comparison op"
  in
  Ok (VInt result)

let eval_float_binop loc op left right =
  expect_float loc left >>= fun l ->
  expect_float loc right >>= fun r ->
  match op with
  | Ast.Add -> Ok (VFloat (l +. r))
  | Ast.Sub -> Ok (VFloat (l -. r))
  | Ast.Mul -> Ok (VFloat (l *. r))
  | Ast.Div -> Ok (VFloat (l /. r))
  | Ast.Mod -> Ctfe_error.unsupported loc "Float modulo"
  | Ast.Lt | Ast.Gt | Ast.Le | Ast.Ge | Ast.Eq | Ast.Ne ->
      invalid_arg "comparison op"

let eval_compare_binop loc op left right =
  match op with
  | Ast.Eq -> Ok (VBool (value_equal left right))
  | Ast.Ne -> Ok (VBool (not (value_equal left right)))
  | Ast.Lt | Ast.Gt | Ast.Le | Ast.Ge -> (
      let compare l r =
        match op with
        | Ast.Lt -> l < r
        | Ast.Gt -> l > r
        | Ast.Le -> l <= r
        | Ast.Ge -> l >= r
        | _ -> false
      in
      match (left.desc, right.desc) with
      | VInt _, VInt _ ->
          expect_int loc left >>= fun l ->
          expect_int loc right >>= fun r -> Ok (VBool (compare l r))
      | VFloat _, VFloat _ ->
          expect_float loc left >>= fun l ->
          expect_float loc right >>= fun r -> Ok (VBool (compare l r))
      | _ ->
          Error
            [
              Ctfe_error.error loc
                (Printf.sprintf "compile_time cannot compare %s and %s"
                   (type_name left.ty) (type_name right.ty));
            ])
  | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod ->
      invalid_arg "arithmetic op"

let eval_string_add loc left right =
  match (left.desc, right.desc) with
  | VString (l, flags), VString (r, _) -> Ok (VString (l ^ r, flags))
  | _ -> Ctfe_error.unsupported loc "non-String binary addition"

let eval_binary_desc loc op left right =
  match op with
  | Ast.Add -> (
      match (left.desc, right.desc) with
      | VString _, VString _ -> eval_string_add loc left right
      | VFloat _, VFloat _ -> eval_float_binop loc op left right
      | _ -> eval_int_binop loc op left right)
  | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod -> (
      match (left.desc, right.desc) with
      | VFloat _, VFloat _ -> eval_float_binop loc op left right
      | _ -> eval_int_binop loc op left right)
  | Ast.Lt | Ast.Gt | Ast.Le | Ast.Ge | Ast.Eq | Ast.Ne ->
      eval_compare_binop loc op left right
