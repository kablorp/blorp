(** Operations over compile-time values.

    These helpers build, inspect, compare, and decode CTFE values. They are kept
    separate from expression evaluation so adding syntax support does not grow
    the value runtime surface by accident. *)

open Ctfe_value

let ( >>= ) = Result.bind
let type_name ty = Types.type_to_string ty
let value_type expr = Typed_ast.value_type expr
let value_loc expr = Typed_ast.loc expr

let is_named_type name ty =
  match Types.head_resolve ty with
  | Ast.TyNamed (actual, _) -> actual = name
  | _ -> false

let scalar_value expr desc =
  Ok { ty = value_type expr; desc; loc = value_loc expr }

let string_flags_for_interp is_multiline =
  { Ast.sf_multiline = is_multiline; sf_raw = false }

let plain_string_flags = string_flags_for_interp false

let string_of_char_code loc code =
  match Uchar.of_int code with
  | uchar ->
      let buffer = Buffer.create 4 in
      Buffer.add_utf_8_uchar buffer uchar;
      Ok (Buffer.contents buffer)
  | exception Invalid_argument _ ->
      Error
        [
          Ctfe_error.error loc
            (Printf.sprintf "compile_time invalid Char codepoint: %d" code);
        ]

let expect_int loc = function
  | { desc = VInt n; _ } -> Ok n
  | value ->
      Error
        [
          Ctfe_error.error loc
            (Printf.sprintf "compile_time expected Int, found %s"
               (type_name value.ty));
        ]

let expect_float loc = function
  | { desc = VFloat n; _ } -> Ok n
  | value ->
      Error
        [
          Ctfe_error.error loc
            (Printf.sprintf "compile_time expected Float, found %s"
               (type_name value.ty));
        ]

let expect_bool loc = function
  | { desc = VBool b; _ } -> Ok b
  | value ->
      Error
        [
          Ctfe_error.error loc
            (Printf.sprintf "compile_time expected Bool, found %s"
               (type_name value.ty));
        ]

let expect_list loc = function
  | { desc = VList values; _ } -> Ok values
  | value ->
      Error
        [
          Ctfe_error.error loc
            (Printf.sprintf "compile_time expected List, found %s"
               (type_name value.ty));
        ]

let expect_dict loc = function
  | { desc = VDict pairs; _ } -> Ok pairs
  | value ->
      Error
        [
          Ctfe_error.error loc
            (Printf.sprintf "compile_time expected Dict, found %s"
               (type_name value.ty));
        ]

let rec value_equal left right =
  match (left.desc, right.desc) with
  | VInt a, VInt b -> a = b
  | VFloat a, VFloat b -> a = b
  | VBool a, VBool b -> a = b
  | VChar a, VChar b -> a = b
  | VString (a, _), VString (b, _) -> a = b
  | VTuple a, VTuple b | VList a, VList b ->
      List.length a = List.length b && List.for_all2 value_equal a b
  | VRecord a, VRecord b ->
      List.length a = List.length b
      && List.for_all2
           (fun (an, av) (bn, bv) -> an = bn && value_equal av bv)
           a b
  | VDict a, VDict b ->
      List.length a = List.length b
      && List.for_all2
           (fun (ak, av) (bk, bv) -> value_equal ak bk && value_equal av bv)
           a b
  | VRange (a_start, a_end), VRange (b_start, b_end) ->
      value_equal a_start b_start && value_equal a_end b_end
  | VVoid, VVoid -> true
  | VClosure _, VClosure _ -> false
  | VConstructor a, VConstructor b ->
      a.name = b.name
      && List.length a.args = List.length b.args
      && List.for_all2 value_equal a.args b.args
  | _ -> false

let int_value expr n = scalar_value expr (VInt (Int64.of_int n))
let bool_value expr b = scalar_value expr (VBool b)

let int_arg_value loc n =
  { ty = Ast.TyNamed ("Int", []); desc = VInt (Int64.of_int n); loc }

let string_value expr text =
  scalar_value expr (VString (text, plain_string_flags))

let call_result_value call_expr value =
  Ok { value with ty = value_type call_expr; loc = Typed_ast.loc call_expr }

let index_upper_bound = Int64.of_int max_int

let index_of_int64 n =
  if n < 0L || n > index_upper_bound then None else Some (Int64.to_int n)

let list_set_at values index elem =
  let rec loop current acc = function
    | [] -> List.rev acc
    | _ :: rest when current = index -> List.rev_append acc (elem :: rest)
    | value :: rest -> loop (current + 1) (value :: acc) rest
  in
  loop 0 [] values

let dict_find pairs key =
  List.find_opt (fun (candidate, _) -> value_equal candidate key) pairs

let dict_set pairs key value =
  let rec loop acc = function
    | [] -> List.rev ((key, value) :: acc)
    | (candidate, _) :: rest when value_equal candidate key ->
        List.rev_append acc ((candidate, value) :: rest)
    | pair :: rest -> loop (pair :: acc) rest
  in
  loop [] pairs

let dict_from_list_entries loc entries =
  let rec loop pairs = function
    | [] -> Ok pairs
    | entry :: rest -> (
        match entry.desc with
        | VTuple [ key; value ] -> loop (dict_set pairs key value) rest
        | _ ->
            Error
              [
                Ctfe_error.error loc
                  (Printf.sprintf
                     "compile_time expected Dict entry tuple, found %s"
                     (type_name entry.ty));
              ])
  in
  loop [] entries

let construct_value ctx call_expr name args =
  let loc = value_loc call_expr in
  match Ctfe_context.constructor_info ctx name with
  | Some info when info.constructor_arity = List.length args ->
      scalar_value call_expr
        (VConstructor
           {
             name;
             args;
             callee = None;
             resolved_call = None;
             constructor_info = Some info;
           })
  | Some info ->
      Error
        [
          Ctfe_error.error loc
            (Printf.sprintf
               "internal CTFE error: constructor '%s' expected %d values, got \
                %d"
               name info.constructor_arity (List.length args));
        ]
  | None ->
      Error
        [
          Ctfe_error.error loc
            (Printf.sprintf
               "internal CTFE error: constructor '%s' is not available during \
                compile-time evaluation"
               name);
        ]

let option_value ctx call_expr = function
  | Some value ->
      construct_value ctx call_expr Ctfe_intrinsic.Source.some_constructor
        [ value ]
  | None ->
      construct_value ctx call_expr Ctfe_intrinsic.Source.none_constructor []

let result_ok_value ctx call_expr value =
  construct_value ctx call_expr Ctfe_intrinsic.Source.ok_constructor [ value ]

let result_err_value ctx call_expr value =
  construct_value ctx call_expr Ctfe_intrinsic.Source.err_constructor [ value ]

let classified_constructor_value = function
  | {
      desc =
        VConstructor
          {
            name;
            args;
            constructor_info = Some { constructor_parent_type; _ };
            _;
          };
      _;
    } ->
      Option.map
        (fun constructor -> (constructor, args))
        (Ctfe_intrinsic.constructor_of_source
           ~parent_type:constructor_parent_type ~constructor_name:name)
  | _ -> None

let option_state loc value =
  match classified_constructor_value value with
  | Some (Ctfe_intrinsic.OptionSomeConstructor, [ value ]) ->
      Ok (OptionSome value)
  | Some (Ctfe_intrinsic.OptionNoneConstructor, []) -> Ok OptionNone
  | _ -> Ctfe_error.unsupported loc "Option helper on non-Option values"

let result_state loc value =
  match classified_constructor_value value with
  | Some (Ctfe_intrinsic.ResultOkConstructor, [ value ]) -> Ok (ResultOk value)
  | Some (Ctfe_intrinsic.ResultErrConstructor, [ value ]) ->
      Ok (ResultErr value)
  | _ -> Ctfe_error.unsupported loc "Result helper on non-Result values"

let option_presence loc value =
  option_state loc value >>= function
  | OptionSome _ -> Ok true
  | OptionNone -> Ok false

let result_presence loc value =
  result_state loc value >>= function
  | ResultOk _ -> Ok true
  | ResultErr _ -> Ok false

let expect_closure loc = function
  | { desc = VClosure closure; _ } -> Ok closure
  | value ->
      Error
        [
          Ctfe_error.error loc
            (Printf.sprintf "compile_time expected pure callback, found %s"
               (type_name value.ty));
        ]

let string_text_of_value loc value =
  match value.desc with
  | VString (text, _) -> Ok text
  | VInt n -> Ok (Int64.to_string n)
  | VFloat n -> Ok (Printf.sprintf "%g" n)
  | VBool true -> Ok "True"
  | VBool false -> Ok "False"
  | VChar code -> string_of_char_code loc code
  | _ ->
      Error
        [
          Ctfe_error.error loc
            (Printf.sprintf
               "compile_time to_string currently supports String, Int, Float, \
                Bool, and Char values, found %s"
               (type_name value.ty));
        ]
