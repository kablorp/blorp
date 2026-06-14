(** CTFE implementations for compiler-owned portable std operations. *)

open Ctfe_value
open Ctfe_value_ops
module Intrinsic = Ctfe_intrinsic

let ( >>= ) = Result.bind
let ( let* ) = Result.bind

let rec eval_imported_call ~eval_callback_call ctx call_expr ~module_path
    ~source_name arg_values =
  let loc = Typed_ast.loc call_expr in
  match Intrinsic.imported_call_of_source ~module_path ~source_name with
  | Some (Intrinsic.ImportedList op as imported_call) ->
      eval_list_call ~eval_callback_call ctx call_expr ~source_name
        ~imported_call op arg_values
  | Some (Intrinsic.ImportedDict op as imported_call) ->
      eval_dict_call ctx call_expr ~source_name ~imported_call op arg_values
  | Some (Intrinsic.ImportedOption op as imported_call) ->
      eval_option_call ~eval_callback_call ctx call_expr ~source_name
        ~imported_call op arg_values
  | Some (Intrinsic.ImportedResult op as imported_call) ->
      eval_result_call ~eval_callback_call ctx call_expr ~source_name
        ~imported_call op arg_values
  | None ->
      Ctfe_error.unsupported loc
        (Intrinsic.imported_unsupported_form ~module_path ~source_name)

and eval_list_call ~eval_callback_call ctx call_expr ~source_name ~imported_call
    op arg_values =
  let loc = Typed_ast.loc call_expr in
  match (op, arg_values) with
  | Intrinsic.ListMake, [ capacity ] ->
      let* _ = expect_int loc capacity in
      scalar_value call_expr (VList [])
  | Intrinsic.ListMap, [ receiver; callback ] ->
      expect_list loc receiver >>= fun values ->
      eval_list_map ~eval_callback_call ctx call_expr callback values
  | Intrinsic.ListFilter, [ receiver; callback ] ->
      expect_list loc receiver >>= fun values ->
      eval_list_filter ~eval_callback_call ctx call_expr callback values
  | Intrinsic.ListFilterMap, [ receiver; callback ] ->
      expect_list loc receiver >>= fun values ->
      eval_list_filter_map ~eval_callback_call ctx call_expr callback values
  | Intrinsic.ListFlatMap, [ receiver; callback ] ->
      expect_list loc receiver >>= fun values ->
      eval_list_flat_map ~eval_callback_call ctx call_expr callback values
  | Intrinsic.ListMapIndexed, [ receiver; callback ] ->
      expect_list loc receiver >>= fun values ->
      eval_list_map_indexed ~eval_callback_call ctx call_expr callback values
  | Intrinsic.ListFoldLeft, [ receiver; initial; callback ] ->
      expect_list loc receiver >>= fun values ->
      eval_list_fold_left ~eval_callback_call ctx call_expr callback initial
        values
  | Intrinsic.ListFoldRight, [ receiver; initial; callback ] ->
      expect_list loc receiver >>= fun values ->
      eval_list_fold_right ~eval_callback_call ctx call_expr callback initial
        values
  | Intrinsic.ListAll, [ receiver; callback ] ->
      expect_list loc receiver >>= fun values ->
      eval_list_all ~eval_callback_call ctx call_expr callback values
  | Intrinsic.ListAny, [ receiver; callback ] ->
      expect_list loc receiver >>= fun values ->
      eval_list_any ~eval_callback_call ctx call_expr callback values
  | Intrinsic.ListAppend, [ receiver; elem ] ->
      expect_list loc receiver >>= fun values ->
      scalar_value call_expr (VList (values @ [ elem ]))
  | Intrinsic.ListConcat, [ left; right ] ->
      expect_list loc left >>= fun left_values ->
      expect_list loc right >>= fun right_values ->
      scalar_value call_expr (VList (left_values @ right_values))
  | Intrinsic.ListSet, [ receiver; index; elem ] ->
      expect_list loc receiver >>= fun values ->
      expect_int loc index >>= fun index_int ->
      let updated =
        match index_of_int64 index_int with
        | Some index when index < List.length values ->
            list_set_at values index elem
        | Some _ | None -> values
      in
      scalar_value call_expr (VList updated)
  | Intrinsic.ListGet, [ receiver; index ] ->
      expect_list loc receiver >>= fun values ->
      expect_int loc index >>= fun index_int ->
      let result =
        match index_of_int64 index_int with
        | Some index -> List.nth_opt values index
        | None -> None
      in
      option_value ctx call_expr result
  | Intrinsic.ListGetOr, [ receiver; index; default_value ] ->
      expect_list loc receiver >>= fun values ->
      expect_int loc index >>= fun index_int ->
      let result =
        match index_of_int64 index_int with
        | Some index ->
            Option.value (List.nth_opt values index) ~default:default_value
        | None -> default_value
      in
      Ok { result with ty = value_type call_expr; loc }
  | Intrinsic.ListContains, [ receiver; elem ] ->
      expect_list loc receiver >>= fun values ->
      bool_value call_expr
        (List.exists (fun value -> value_equal value elem) values)
  | Intrinsic.ListLength, [ receiver ] ->
      expect_list loc receiver >>= fun values ->
      int_value call_expr (List.length values)
  | _ ->
      Ctfe_error.unsupported loc
        (Intrinsic.imported_call_unsupported_form imported_call ~source_name)

and eval_list_map ~eval_callback_call ctx call_expr callback values =
  let rec loop acc = function
    | [] -> scalar_value call_expr (VList (List.rev acc))
    | value :: rest ->
        eval_callback_call ctx call_expr callback [ value ] >>= fun mapped ->
        loop (mapped :: acc) rest
  in
  loop [] values

and eval_list_filter ~eval_callback_call ctx call_expr callback values =
  let loc = Typed_ast.loc call_expr in
  let rec loop acc = function
    | [] -> scalar_value call_expr (VList (List.rev acc))
    | value :: rest ->
        eval_callback_call ctx call_expr callback [ value ] >>= fun keep ->
        expect_bool loc keep >>= fun keep ->
        if keep then loop (value :: acc) rest else loop acc rest
  in
  loop [] values

and eval_list_filter_map ~eval_callback_call ctx call_expr callback values =
  let loc = Typed_ast.loc call_expr in
  let rec loop acc = function
    | [] -> scalar_value call_expr (VList (List.rev acc))
    | value :: rest -> (
        eval_callback_call ctx call_expr callback [ value ] >>= fun mapped ->
        option_state loc mapped >>= function
        | OptionSome value -> loop (value :: acc) rest
        | OptionNone -> loop acc rest)
  in
  loop [] values

and eval_list_flat_map ~eval_callback_call ctx call_expr callback values =
  let loc = Typed_ast.loc call_expr in
  let rec loop acc = function
    | [] -> scalar_value call_expr (VList (List.rev acc))
    | value :: rest ->
        eval_callback_call ctx call_expr callback [ value ] >>= fun mapped ->
        expect_list loc mapped >>= fun mapped_values ->
        loop (List.rev_append mapped_values acc) rest
  in
  loop [] values

and eval_list_map_indexed ~eval_callback_call ctx call_expr callback values =
  let loc = Typed_ast.loc call_expr in
  let rec loop index acc = function
    | [] -> scalar_value call_expr (VList (List.rev acc))
    | value :: rest ->
        let index_value = int_arg_value loc index in
        eval_callback_call ctx call_expr callback [ index_value; value ]
        >>= fun mapped -> loop (index + 1) (mapped :: acc) rest
  in
  loop 0 [] values

and eval_list_fold_left ~eval_callback_call ctx call_expr callback initial
    values =
  let rec loop acc = function
    | [] -> call_result_value call_expr acc
    | value :: rest ->
        eval_callback_call ctx call_expr callback [ acc; value ] >>= fun acc ->
        loop acc rest
  in
  loop initial values

and eval_list_fold_right ~eval_callback_call ctx call_expr callback initial
    values =
  let rec loop acc = function
    | [] -> call_result_value call_expr acc
    | value :: rest ->
        eval_callback_call ctx call_expr callback [ value; acc ] >>= fun acc ->
        loop acc rest
  in
  loop initial (List.rev values)

and eval_list_all ~eval_callback_call ctx call_expr callback values =
  let loc = Typed_ast.loc call_expr in
  let rec loop = function
    | [] -> bool_value call_expr true
    | value :: rest ->
        eval_callback_call ctx call_expr callback [ value ] >>= fun result ->
        expect_bool loc result >>= fun result ->
        if result then loop rest else bool_value call_expr false
  in
  loop values

and eval_list_any ~eval_callback_call ctx call_expr callback values =
  let loc = Typed_ast.loc call_expr in
  let rec loop = function
    | [] -> bool_value call_expr false
    | value :: rest ->
        eval_callback_call ctx call_expr callback [ value ] >>= fun result ->
        expect_bool loc result >>= fun result ->
        if result then bool_value call_expr true else loop rest
  in
  loop values

and eval_dict_call ctx call_expr ~source_name ~imported_call op arg_values =
  let loc = Typed_ast.loc call_expr in
  match (op, arg_values) with
  | Intrinsic.DictMake, [] -> scalar_value call_expr (VDict [])
  | Intrinsic.DictWithCapacity, [ capacity ] ->
      let* _ = expect_int loc capacity in
      scalar_value call_expr (VDict [])
  | Intrinsic.DictFromList, [ entries ] ->
      expect_list loc entries >>= fun entries ->
      dict_from_list_entries loc entries >>= fun pairs ->
      scalar_value call_expr (VDict pairs)
  | Intrinsic.DictSet, [ receiver; key; value ] ->
      expect_dict loc receiver >>= fun pairs ->
      scalar_value call_expr (VDict (dict_set pairs key value))
  | Intrinsic.DictGet, [ receiver; key ] ->
      expect_dict loc receiver >>= fun pairs ->
      let result = Option.map snd (dict_find pairs key) in
      option_value ctx call_expr result
  | Intrinsic.DictGetOr, [ receiver; key; default_value ] ->
      expect_dict loc receiver >>= fun pairs ->
      let result =
        match dict_find pairs key with
        | Some (_, value) -> value
        | None -> default_value
      in
      Ok { result with ty = value_type call_expr; loc }
  | Intrinsic.DictContains, [ receiver; key ] ->
      expect_dict loc receiver >>= fun pairs ->
      bool_value call_expr (Option.is_some (dict_find pairs key))
  | Intrinsic.DictLength, [ receiver ] ->
      expect_dict loc receiver >>= fun pairs ->
      int_value call_expr (List.length pairs)
  | _ ->
      Ctfe_error.unsupported loc
        (Intrinsic.imported_call_unsupported_form imported_call ~source_name)

and eval_option_call ~eval_callback_call ctx call_expr ~source_name
    ~imported_call op arg_values =
  let loc = Typed_ast.loc call_expr in
  match (op, arg_values) with
  | Intrinsic.OptionGetOr, [ receiver; default_value ] -> (
      option_state loc receiver >>= function
      | OptionSome value -> Ok { value with ty = value_type call_expr; loc }
      | OptionNone -> Ok { default_value with ty = value_type call_expr; loc })
  | Intrinsic.OptionGetOrElse, [ receiver; default_fn ] -> (
      option_state loc receiver >>= function
      | OptionSome value -> call_result_value call_expr value
      | OptionNone -> eval_callback_call ctx call_expr default_fn [])
  | Intrinsic.OptionMap, [ receiver; callback ] -> (
      option_state loc receiver >>= function
      | OptionSome value ->
          eval_callback_call ctx call_expr callback [ value ] >>= fun mapped ->
          option_value ctx call_expr (Some mapped)
      | OptionNone -> option_value ctx call_expr None)
  | Intrinsic.OptionAndThen, [ receiver; callback ] -> (
      option_state loc receiver >>= function
      | OptionSome value ->
          eval_callback_call ctx call_expr callback [ value ]
          >>= call_result_value call_expr
      | OptionNone -> option_value ctx call_expr None)
  | Intrinsic.OptionFilter, [ receiver; callback ] -> (
      option_state loc receiver >>= function
      | OptionSome value ->
          eval_callback_call ctx call_expr callback [ value ] >>= fun keep ->
          expect_bool loc keep >>= fun keep ->
          if keep then option_value ctx call_expr (Some value)
          else option_value ctx call_expr None
      | OptionNone -> option_value ctx call_expr None)
  | Intrinsic.OptionIsSome, [ receiver ] ->
      option_presence loc receiver >>= fun present ->
      bool_value call_expr present
  | Intrinsic.OptionIsNone, [ receiver ] ->
      option_presence loc receiver >>= fun present ->
      bool_value call_expr (not present)
  | Intrinsic.OptionToResult, [ receiver; error_value ] -> (
      option_state loc receiver >>= function
      | OptionSome value -> result_ok_value ctx call_expr value
      | OptionNone -> result_err_value ctx call_expr error_value)
  | _ ->
      Ctfe_error.unsupported loc
        (Intrinsic.imported_call_unsupported_form imported_call ~source_name)

and eval_result_call ~eval_callback_call ctx call_expr ~source_name
    ~imported_call op arg_values =
  let loc = Typed_ast.loc call_expr in
  match (op, arg_values) with
  | Intrinsic.ResultFromOption, [ opt; error_value ] -> (
      option_state loc opt >>= function
      | OptionSome value -> result_ok_value ctx call_expr value
      | OptionNone -> result_err_value ctx call_expr error_value)
  | Intrinsic.ResultGetOr, [ receiver; default_value ] -> (
      result_state loc receiver >>= function
      | ResultOk value -> Ok { value with ty = value_type call_expr; loc }
      | ResultErr _ -> Ok { default_value with ty = value_type call_expr; loc })
  | Intrinsic.ResultGetOrElse, [ receiver; default_fn ] -> (
      result_state loc receiver >>= function
      | ResultOk value -> call_result_value call_expr value
      | ResultErr error_value ->
          eval_callback_call ctx call_expr default_fn [ error_value ])
  | Intrinsic.ResultMap, [ receiver; callback ] -> (
      result_state loc receiver >>= function
      | ResultOk value ->
          eval_callback_call ctx call_expr callback [ value ] >>= fun mapped ->
          result_ok_value ctx call_expr mapped
      | ResultErr error_value -> result_err_value ctx call_expr error_value)
  | Intrinsic.ResultMapErr, [ receiver; callback ] -> (
      result_state loc receiver >>= function
      | ResultOk value -> result_ok_value ctx call_expr value
      | ResultErr error_value ->
          eval_callback_call ctx call_expr callback [ error_value ]
          >>= fun mapped_error -> result_err_value ctx call_expr mapped_error)
  | Intrinsic.ResultAndThen, [ receiver; callback ] -> (
      result_state loc receiver >>= function
      | ResultOk value ->
          eval_callback_call ctx call_expr callback [ value ]
          >>= call_result_value call_expr
      | ResultErr error_value -> result_err_value ctx call_expr error_value)
  | Intrinsic.ResultIsOk, [ receiver ] ->
      result_presence loc receiver >>= fun present ->
      bool_value call_expr present
  | Intrinsic.ResultIsErr, [ receiver ] ->
      result_presence loc receiver >>= fun present ->
      bool_value call_expr (not present)
  | Intrinsic.ResultToOption, [ receiver ] -> (
      result_state loc receiver >>= function
      | ResultOk value -> option_value ctx call_expr (Some value)
      | ResultErr _ -> option_value ctx call_expr None)
  | _ ->
      Ctfe_error.unsupported loc
        (Intrinsic.imported_call_unsupported_form imported_call ~source_name)
