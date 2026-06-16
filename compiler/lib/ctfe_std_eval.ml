(** CTFE implementations for compiler-owned portable std operations. *)

open Ctfe_value
open Ctfe_value_ops
module Intrinsic = Ctfe_intrinsic
module IR = Ctfe_ir

let ( >>= ) = Result.bind
let ( let* ) = Result.bind
let string_not_found_index = -1

(* These helpers mirror the current std/string Core intrinsics, which operate
   on byte offsets for indexing, slicing, splitting, replacement, and chars().
   Keep CTFE behavior in lockstep with that runtime contract rather than
   switching individual helpers to Unicode codepoint semantics here. *)
let clamp_substring_start text_length requested_start =
  if requested_start <= 0L then 0
  else
    let text_length64 = Int64.of_int text_length in
    if requested_start > text_length64 then text_length
    else Int64.to_int requested_start

let clamp_substring_length text_length start requested_length =
  if requested_length <= 0L then 0
  else
    let available = text_length - start in
    let available64 = Int64.of_int available in
    if requested_length > available64 then available
    else Int64.to_int requested_length

let string_has_prefix text prefix =
  let text_length = String.length text in
  let prefix_length = String.length prefix in
  prefix_length <= text_length && String.sub text 0 prefix_length = prefix

let string_has_suffix text suffix =
  let text_length = String.length text in
  let suffix_length = String.length suffix in
  suffix_length <= text_length
  && String.sub text (text_length - suffix_length) suffix_length = suffix

let string_index_of_from text needle start =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let start = max 0 start in
  if needle_length = 0 then
    if start <= text_length then start else string_not_found_index
  else if start + needle_length > text_length then string_not_found_index
  else
    let last_start = text_length - needle_length in
    let rec loop index =
      if index > last_start then string_not_found_index
      else if String.sub text index needle_length = needle then index
      else loop (index + 1)
    in
    loop start

let string_index_of text needle = string_index_of_from text needle 0

let string_count text needle =
  let text_length = String.length text in
  let needle_length = String.length needle in
  if needle_length = 0 || needle_length > text_length then 0
  else
    let rec loop index count =
      if index + needle_length > text_length then count
      else if String.sub text index needle_length = needle then
        loop (index + needle_length) (count + 1)
      else loop (index + 1) count
    in
    loop 0 0

let string_split text delimiter =
  let delimiter_length = String.length delimiter in
  if delimiter_length = 0 then [ text ]
  else
    let text_length = String.length text in
    let rec loop acc segment_start search_start =
      match string_index_of_from text delimiter search_start with
      | index when index = string_not_found_index ->
          let segment =
            String.sub text segment_start (text_length - segment_start)
          in
          List.rev (segment :: acc)
      | index ->
          let segment = String.sub text segment_start (index - segment_start) in
          let next_start = index + delimiter_length in
          loop (segment :: acc) next_start next_start
    in
    loop [] 0 0

let string_replace text old_text new_text =
  let old_length = String.length old_text in
  if old_length = 0 then text
  else
    let text_length = String.length text in
    let buffer = Buffer.create text_length in
    let rec loop segment_start search_start =
      match string_index_of_from text old_text search_start with
      | index when index = string_not_found_index ->
          Buffer.add_substring buffer text segment_start
            (text_length - segment_start);
          Buffer.contents buffer
      | index ->
          Buffer.add_substring buffer text segment_start (index - segment_start);
          Buffer.add_string buffer new_text;
          let next_start = index + old_length in
          loop next_start next_start
    in
    loop 0 0

let string_slice text start length = String.sub text start length

let string_drop_left text count =
  let text_length = String.length text in
  let start =
    if count <= 0L then 0
    else
      let text_length64 = Int64.of_int text_length in
      if count > text_length64 then text_length else Int64.to_int count
  in
  string_slice text start (text_length - start)

let string_take_left text count =
  let text_length = String.length text in
  let length =
    if count <= 0L then 0
    else
      let text_length64 = Int64.of_int text_length in
      if count > text_length64 then text_length else Int64.to_int count
  in
  string_slice text 0 length

let is_trim_whitespace = function
  | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false

let string_trim_left text =
  let text_length = String.length text in
  let rec loop index =
    if index >= text_length then text_length
    else if is_trim_whitespace text.[index] then loop (index + 1)
    else index
  in
  let start = loop 0 in
  string_slice text start (text_length - start)

let string_trim_right text =
  let rec loop index =
    if index <= 0 then 0
    else if is_trim_whitespace text.[index - 1] then loop (index - 1)
    else index
  in
  let length = loop (String.length text) in
  string_slice text 0 length

let string_trim text =
  let text_length = String.length text in
  let rec left index =
    if index >= text_length then text_length
    else if is_trim_whitespace text.[index] then left (index + 1)
    else index
  in
  let start = left 0 in
  let rec right index =
    if index <= start then start
    else if is_trim_whitespace text.[index - 1] then right (index - 1)
    else index
  in
  let stop = right text_length in
  string_slice text start (stop - start)

let string_reverse text =
  let text_length = String.length text in
  String.init text_length (fun index -> text.[text_length - 1 - index])

let chars_of_string loc text =
  let values =
    List.init (String.length text) (fun index ->
        char_arg_value loc (Char.code text.[index]))
  in
  VList values

let string_of_chars loc values =
  let buffer = Buffer.create (List.length values) in
  let rec loop = function
    | [] -> Ok (Buffer.contents buffer)
    | value :: rest ->
        expect_char loc value >>= fun code ->
        string_of_char_code loc code >>= fun encoded ->
        Buffer.add_string buffer encoded;
        loop rest
  in
  loop values

let repeat_string loc text repetitions =
  if repetitions <= 0L || String.length text = 0 then Ok ""
  else
    let text_length = String.length text in
    let max_output_length = Int64.of_int Sys.max_string_length in
    if repetitions > Int64.div max_output_length (Int64.of_int text_length) then
      Error
        [
          Ctfe_error.error loc "compile_time string repeat result is too large";
        ]
    else
      let output_length =
        Int64.to_int (Int64.mul (Int64.of_int text_length) repetitions)
      in
      let buffer = Buffer.create output_length in
      for _ = 1 to Int64.to_int repetitions do
        Buffer.add_string buffer text
      done;
      Ok (Buffer.contents buffer)

let eval_builtin_call ctx call_expr ~source_name ~builtin_intrinsic arg_values =
  let loc = call_expr.IR.loc in
  match (builtin_intrinsic, arg_values) with
  | Some Intrinsic.BuiltinToString, [ receiver ] ->
      string_text_of_value loc receiver >>= string_value call_expr
  | Some Intrinsic.BuiltinLength, [ receiver ] -> (
      match receiver.desc with
      | VList values -> int_value call_expr (List.length values)
      | VDict pairs -> int_value call_expr (List.length pairs)
      | VString (text, _) -> int_value call_expr (String.length text)
      | _ -> Ctfe_error.unsupported loc "length builtin on this value")
  | Some Intrinsic.BuiltinGet, [ receiver; key ] -> (
      match receiver.desc with
      | VList values ->
          expect_int loc key >>= fun index_int ->
          let result =
            match index_of_int64 index_int with
            | Some index -> List.nth_opt values index
            | None -> None
          in
          option_value ctx call_expr result
      | VDict pairs ->
          let result = Option.map snd (dict_find pairs key) in
          option_value ctx call_expr result
      | VString (text, _) ->
          expect_int loc key >>= fun index ->
          let result =
            match index_of_int64 index with
            | Some index when index < String.length text ->
                Some (char_arg_value loc (Char.code text.[index]))
            | Some _ | None -> None
          in
          option_value ctx call_expr result
      | _ -> Ctfe_error.unsupported loc "get builtin on this value")
  | Some Intrinsic.BuiltinStringFromChar, [ char ] ->
      expect_char loc char >>= string_of_char_code loc
      >>= string_value call_expr
  | Some Intrinsic.BuiltinStringChars, [ receiver ] ->
      expect_string loc receiver >>= fun text ->
      scalar_value call_expr (chars_of_string loc text)
  | Some Intrinsic.BuiltinStringFromChars, [ chars ] ->
      expect_list loc chars >>= fun chars ->
      string_of_chars loc chars >>= string_value call_expr
  | _ ->
      Ctfe_error.unsupported loc
        (Intrinsic.builtin_unsupported_form source_name)

let eval_trait_call call_expr ~trait_intrinsic arg_values =
  let loc = call_expr.IR.loc in
  match (trait_intrinsic, arg_values) with
  | Some Intrinsic.TraitStringableToString, [ receiver ] ->
      string_text_of_value loc receiver >>= string_value call_expr
  | Some Intrinsic.TraitHasLengthLength, [ receiver ] -> (
      match receiver.desc with
      | VList values -> int_value call_expr (List.length values)
      | VDict pairs -> int_value call_expr (List.length pairs)
      | VString (text, _) -> int_value call_expr (String.length text)
      | _ -> Ctfe_error.unsupported loc "HasLength.length on this value")
  | _ -> Ctfe_error.unsupported loc "trait method calls"

let rec eval_imported_call ~eval_callback_call ctx call_expr ~module_path
    ~source_name ~imported_intrinsic arg_values =
  let loc = call_expr.IR.loc in
  match imported_intrinsic with
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
  | Some (Intrinsic.ImportedString op as imported_call) ->
      eval_string_call ctx call_expr ~source_name ~imported_call op arg_values
  | None ->
      Ctfe_error.unsupported loc
        (Intrinsic.imported_unsupported_form ~module_path ~source_name)

and eval_list_call ~eval_callback_call ctx call_expr ~source_name ~imported_call
    op arg_values =
  let loc = call_expr.IR.loc in
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
  let loc = call_expr.IR.loc in
  let rec loop acc = function
    | [] -> scalar_value call_expr (VList (List.rev acc))
    | value :: rest ->
        eval_callback_call ctx call_expr callback [ value ] >>= fun keep ->
        expect_bool loc keep >>= fun keep ->
        if keep then loop (value :: acc) rest else loop acc rest
  in
  loop [] values

and eval_list_filter_map ~eval_callback_call ctx call_expr callback values =
  let loc = call_expr.IR.loc in
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
  let loc = call_expr.IR.loc in
  let rec loop acc = function
    | [] -> scalar_value call_expr (VList (List.rev acc))
    | value :: rest ->
        eval_callback_call ctx call_expr callback [ value ] >>= fun mapped ->
        expect_list loc mapped >>= fun mapped_values ->
        loop (List.rev_append mapped_values acc) rest
  in
  loop [] values

and eval_list_map_indexed ~eval_callback_call ctx call_expr callback values =
  let loc = call_expr.IR.loc in
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
  let loc = call_expr.IR.loc in
  let rec loop = function
    | [] -> bool_value call_expr true
    | value :: rest ->
        eval_callback_call ctx call_expr callback [ value ] >>= fun result ->
        expect_bool loc result >>= fun result ->
        if result then loop rest else bool_value call_expr false
  in
  loop values

and eval_list_any ~eval_callback_call ctx call_expr callback values =
  let loc = call_expr.IR.loc in
  let rec loop = function
    | [] -> bool_value call_expr false
    | value :: rest ->
        eval_callback_call ctx call_expr callback [ value ] >>= fun result ->
        expect_bool loc result >>= fun result ->
        if result then bool_value call_expr true else loop rest
  in
  loop values

and eval_dict_call ctx call_expr ~source_name ~imported_call op arg_values =
  let loc = call_expr.IR.loc in
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

and eval_string_call ctx call_expr ~source_name ~imported_call op arg_values =
  let loc = call_expr.IR.loc in
  match (op, arg_values) with
  | Intrinsic.StringLength, [ receiver ] ->
      expect_string loc receiver >>= fun text ->
      int_value call_expr (String.length text)
  | Intrinsic.StringSubstring, [ receiver; start; requested_length ] ->
      expect_string loc receiver >>= fun text ->
      expect_int loc start >>= fun start ->
      expect_int loc requested_length >>= fun requested_length ->
      let text_length = String.length text in
      let start = clamp_substring_start text_length start in
      let length = clamp_substring_length text_length start requested_length in
      string_value call_expr (String.sub text start length)
  | Intrinsic.StringStartsWith, [ receiver; prefix ] ->
      expect_string loc receiver >>= fun text ->
      expect_string loc prefix >>= fun prefix ->
      bool_value call_expr (string_has_prefix text prefix)
  | Intrinsic.StringEndsWith, [ receiver; suffix ] ->
      expect_string loc receiver >>= fun text ->
      expect_string loc suffix >>= fun suffix ->
      bool_value call_expr (string_has_suffix text suffix)
  | Intrinsic.StringContains, [ receiver; needle ] ->
      expect_string loc receiver >>= fun text ->
      expect_string loc needle >>= fun needle ->
      bool_value call_expr
        (string_index_of text needle <> string_not_found_index)
  | Intrinsic.StringRawIndexOf, [ receiver; needle ] ->
      expect_string loc receiver >>= fun text ->
      expect_string loc needle >>= fun needle ->
      int_value call_expr (string_index_of text needle)
  | Intrinsic.StringIndexOf, [ receiver; needle ] ->
      expect_string loc receiver >>= fun text ->
      expect_string loc needle >>= fun needle ->
      let index = string_index_of text needle in
      if index = string_not_found_index then option_value ctx call_expr None
      else option_value ctx call_expr (Some (int_arg_value loc index))
  | Intrinsic.StringRepeat, [ receiver; repetitions ] ->
      expect_string loc receiver >>= fun text ->
      expect_int loc repetitions >>= fun repetitions ->
      repeat_string loc text repetitions >>= string_value call_expr
  | Intrinsic.StringSplit, [ receiver; delimiter ] ->
      expect_string loc receiver >>= fun text ->
      expect_string loc delimiter >>= fun delimiter ->
      let parts =
        List.map (string_arg_value loc) (string_split text delimiter)
      in
      scalar_value call_expr (VList parts)
  | Intrinsic.StringReplace, [ receiver; old_text; new_text ] ->
      expect_string loc receiver >>= fun text ->
      expect_string loc old_text >>= fun old_text ->
      expect_string loc new_text >>= fun new_text ->
      string_value call_expr (string_replace text old_text new_text)
  | Intrinsic.StringDropLeft, [ receiver; count ] ->
      expect_string loc receiver >>= fun text ->
      expect_int loc count >>= fun count ->
      string_value call_expr (string_drop_left text count)
  | Intrinsic.StringTakeLeft, [ receiver; count ] ->
      expect_string loc receiver >>= fun text ->
      expect_int loc count >>= fun count ->
      string_value call_expr (string_take_left text count)
  | Intrinsic.StringTrim, [ receiver ] ->
      expect_string loc receiver >>= fun text ->
      string_value call_expr (string_trim text)
  | Intrinsic.StringTrimLeft, [ receiver ] ->
      expect_string loc receiver >>= fun text ->
      string_value call_expr (string_trim_left text)
  | Intrinsic.StringTrimRight, [ receiver ] ->
      expect_string loc receiver >>= fun text ->
      string_value call_expr (string_trim_right text)
  | Intrinsic.StringReverse, [ receiver ] ->
      expect_string loc receiver >>= fun text ->
      string_value call_expr (string_reverse text)
  | Intrinsic.StringCount, [ receiver; needle ] ->
      expect_string loc receiver >>= fun text ->
      expect_string loc needle >>= fun needle ->
      int_value call_expr (string_count text needle)
  | Intrinsic.StringGet, [ receiver; index ] ->
      expect_string loc receiver >>= fun text ->
      expect_int loc index >>= fun index ->
      let result =
        match index_of_int64 index with
        | Some index when index < String.length text ->
            Some (char_arg_value loc (Char.code text.[index]))
        | Some _ | None -> None
      in
      option_value ctx call_expr result
  | Intrinsic.StringGetOr, [ receiver; index; default_value ] ->
      expect_string loc receiver >>= fun text ->
      expect_int loc index >>= fun index ->
      let result =
        match index_of_int64 index with
        | Some index when index < String.length text ->
            char_arg_value loc (Char.code text.[index])
        | Some _ | None -> default_value
      in
      Ok { result with ty = value_type call_expr; loc }
  | Intrinsic.StringFromChar, [ char ] ->
      expect_char loc char >>= string_of_char_code loc
      >>= string_value call_expr
  | Intrinsic.StringChars, [ receiver ] ->
      expect_string loc receiver >>= fun text ->
      scalar_value call_expr (chars_of_string loc text)
  | Intrinsic.StringFromChars, [ chars ] ->
      expect_list loc chars >>= fun chars ->
      string_of_chars loc chars >>= string_value call_expr
  | _ ->
      Ctfe_error.unsupported loc
        (Intrinsic.imported_call_unsupported_form imported_call ~source_name)

and eval_option_call ~eval_callback_call ctx call_expr ~source_name
    ~imported_call op arg_values =
  let loc = call_expr.IR.loc in
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
  let loc = call_expr.IR.loc in
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
