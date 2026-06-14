(** Pattern matching over compile-time values. *)

open Ctfe_value

let ( >>= ) = Result.bind

let literal_matches lit value =
  match (lit, value.desc) with
  | Ast.LitInt left, VInt right -> left = right
  | Ast.LitFloat left, VFloat right -> left = right
  | Ast.LitBool left, VBool right -> left = right
  | Ast.LitChar left, VChar right -> left = right
  | Ast.LitString (left, _), VString (right, _) -> left = right
  | Ast.LitInt128 _, _ -> false
  | _, _ -> false

let rec bind ctx pattern value =
  match pattern with
  | Ast.PatWildcard -> Ok (Some [])
  | Ast.PatVar name when Ctfe_context.constructor_is_nullary ctx name -> (
      match value.desc with
      | VConstructor { name = value_name; args = []; _ } when name = value_name
        ->
          Ok (Some [])
      | _ -> Ok None)
  | Ast.PatVar name -> Ok (Some [ (name, value) ])
  | Ast.PatLiteral lit ->
      if literal_matches lit value then Ok (Some []) else Ok None
  | Ast.PatTuple patterns -> (
      match value.desc with
      | VTuple values -> bind_list ctx patterns values
      | _ -> Ok None)
  | Ast.PatConstructor (name, patterns) | Ast.PatQualified (_, name, patterns)
    -> (
      match value.desc with
      | VConstructor { name = value_name; args; _ }
        when name = value_name && List.length patterns = List.length args ->
          bind_list ctx patterns args
      | _ -> Ok None)
  | Ast.PatList (patterns, spread) -> (
      match value.desc with
      | VList values -> bind_list_pattern ctx patterns spread value values
      | _ -> Ok None)
  | Ast.PatOr patterns -> bind_or_pattern ctx patterns value

and bind_list ctx patterns values =
  if List.length patterns <> List.length values then Ok None
  else
    let rec loop acc patterns values =
      match (patterns, values) with
      | [], [] -> Ok (Some (List.rev acc))
      | pattern :: rest_patterns, value :: rest_values -> (
          match bind ctx pattern value with
          | Error _ as err -> err
          | Ok None -> Ok None
          | Ok (Some bindings) ->
              loop (List.rev_append bindings acc) rest_patterns rest_values)
      | _ -> Ok None
    in
    loop [] patterns values

and bind_list_pattern ctx patterns spread original values =
  let prefix_count = List.length patterns in
  if List.length values < prefix_count then Ok None
  else
    let rec take n acc rest =
      if n = 0 then (List.rev acc, rest)
      else
        match rest with
        | [] -> (List.rev acc, [])
        | value :: rest -> take (n - 1) (value :: acc) rest
    in
    let prefix_values, remaining_values = take prefix_count [] values in
    bind_list ctx patterns prefix_values >>= function
    | None -> Ok None
    | Some prefix_bindings -> (
        match spread with
        | None ->
            if remaining_values = [] then Ok (Some prefix_bindings) else Ok None
        | Some spread_pattern -> (
            let remaining =
              {
                original with
                desc = VList remaining_values;
                loc = original.loc;
              }
            in
            bind ctx spread_pattern remaining >>= function
            | None -> Ok None
            | Some spread_bindings ->
                Ok (Some (prefix_bindings @ spread_bindings))))

and bind_or_pattern ctx patterns value =
  let rec loop = function
    | [] -> Ok None
    | pattern :: rest -> (
        match bind ctx pattern value with
        | Error _ as err -> err
        | Ok None -> loop rest
        | Ok (Some _) as matched -> matched)
  in
  loop patterns
