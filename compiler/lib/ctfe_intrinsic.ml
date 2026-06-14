(** Source identities admitted to compile-time evaluation.

    The evaluator owns control flow and value execution. This module owns the
    narrow admission table for compiler-known std/builtin operations so CTFE
    support does not grow through scattered source-name checks. *)

module Source = struct
  let dict_type = "Dict"
  let option_type = "Option"
  let result_type = "Result"
  let dict_module = "std/dict"
  let list_module = "std/list"
  let dict_length_builtin = "std/dict.length"
  let option_module = "std/option"
  let result_module = "std/result"
  let list_length_builtin = "std/list.length"
  let has_length_trait = "HasLength"
  let stringable_trait = "Stringable"
  let contains = "contains"
  let concat = "concat"
  let dict = "dict"
  let from_option = "from_option"
  let from_list = "from_list"
  let get = "get"
  let get_or = "get_or"
  let get_or_else = "get_or_else"
  let is_err = "is_err"
  let is_none = "is_none"
  let is_ok = "is_ok"
  let is_some = "is_some"
  let length = "length"
  let list = "list"
  let map = "map"
  let map_indexed = "map_indexed"
  let map_err = "map_err"
  let none_constructor = "None"
  let err_constructor = "Err"
  let ok_constructor = "Ok"
  let set = "set"
  let some_constructor = "Some"
  let append = "append"
  let and_then = "and_then"
  let any = "any"
  let filter = "filter"
  let filter_map = "filter_map"
  let flat_map = "flat_map"
  let fold_left = "fold_left"
  let fold_right = "fold_right"
  let all = "all"
  let to_option = "to_option"
  let to_result = "to_result"
  let to_string = "to_string"
  let with_capacity = "with_capacity"
end

type imported_module = List | Dict | Option | Result
type builtin_call = BuiltinToString | BuiltinLength
type trait_call = TraitStringableToString | TraitHasLengthLength

type constructor =
  | OptionSomeConstructor
  | OptionNoneConstructor
  | ResultOkConstructor
  | ResultErrConstructor

type list_op =
  | ListMake
  | ListMap
  | ListFilter
  | ListFilterMap
  | ListFlatMap
  | ListMapIndexed
  | ListFoldLeft
  | ListFoldRight
  | ListAll
  | ListAny
  | ListAppend
  | ListConcat
  | ListSet
  | ListGet
  | ListGetOr
  | ListContains
  | ListLength

type dict_op =
  | DictMake
  | DictWithCapacity
  | DictFromList
  | DictSet
  | DictGet
  | DictGetOr
  | DictContains
  | DictLength

type option_op =
  | OptionGetOr
  | OptionGetOrElse
  | OptionMap
  | OptionAndThen
  | OptionFilter
  | OptionIsSome
  | OptionIsNone
  | OptionToResult

type result_op =
  | ResultFromOption
  | ResultGetOr
  | ResultGetOrElse
  | ResultMap
  | ResultMapErr
  | ResultAndThen
  | ResultIsOk
  | ResultIsErr
  | ResultToOption

type imported_call =
  | ImportedList of list_op
  | ImportedDict of dict_op
  | ImportedOption of option_op
  | ImportedResult of result_op

let module_path_of_imported_call = function
  | ImportedList _ -> Source.list_module
  | ImportedDict _ -> Source.dict_module
  | ImportedOption _ -> Source.option_module
  | ImportedResult _ -> Source.result_module

let imported_module_of_path = function
  | path when path = Source.list_module -> Some List
  | path when path = Source.dict_module -> Some Dict
  | path when path = Source.option_module -> Some Option
  | path when path = Source.result_module -> Some Result
  | _ -> None

let list_op_of_source_name = function
  | name when name = Source.list -> Some ListMake
  | name when name = Source.map -> Some ListMap
  | name when name = Source.filter -> Some ListFilter
  | name when name = Source.filter_map -> Some ListFilterMap
  | name when name = Source.flat_map -> Some ListFlatMap
  | name when name = Source.map_indexed -> Some ListMapIndexed
  | name when name = Source.fold_left -> Some ListFoldLeft
  | name when name = Source.fold_right -> Some ListFoldRight
  | name when name = Source.all -> Some ListAll
  | name when name = Source.any -> Some ListAny
  | name when name = Source.append -> Some ListAppend
  | name when name = Source.concat -> Some ListConcat
  | name when name = Source.set -> Some ListSet
  | name when name = Source.get -> Some ListGet
  | name when name = Source.get_or -> Some ListGetOr
  | name when name = Source.contains -> Some ListContains
  | name when name = Source.length -> Some ListLength
  | _ -> None

let dict_op_of_source_name = function
  | name when name = Source.dict -> Some DictMake
  | name when name = Source.with_capacity -> Some DictWithCapacity
  | name when name = Source.from_list -> Some DictFromList
  | name when name = Source.set -> Some DictSet
  | name when name = Source.get -> Some DictGet
  | name when name = Source.get_or -> Some DictGetOr
  | name when name = Source.contains -> Some DictContains
  | name when name = Source.length -> Some DictLength
  | _ -> None

let option_op_of_source_name = function
  | name when name = Source.get_or -> Some OptionGetOr
  | name when name = Source.get_or_else -> Some OptionGetOrElse
  | name when name = Source.map -> Some OptionMap
  | name when name = Source.and_then -> Some OptionAndThen
  | name when name = Source.filter -> Some OptionFilter
  | name when name = Source.is_some -> Some OptionIsSome
  | name when name = Source.is_none -> Some OptionIsNone
  | name when name = Source.to_result -> Some OptionToResult
  | _ -> None

let result_op_of_source_name = function
  | name when name = Source.from_option -> Some ResultFromOption
  | name when name = Source.get_or -> Some ResultGetOr
  | name when name = Source.get_or_else -> Some ResultGetOrElse
  | name when name = Source.map -> Some ResultMap
  | name when name = Source.map_err -> Some ResultMapErr
  | name when name = Source.and_then -> Some ResultAndThen
  | name when name = Source.is_ok -> Some ResultIsOk
  | name when name = Source.is_err -> Some ResultIsErr
  | name when name = Source.to_option -> Some ResultToOption
  | _ -> None

let imported_call_of_source ~module_path ~source_name =
  match imported_module_of_path module_path with
  | Some List ->
      Option.map
        (fun op -> ImportedList op)
        (list_op_of_source_name source_name)
  | Some Dict ->
      Option.map
        (fun op -> ImportedDict op)
        (dict_op_of_source_name source_name)
  | Some Option ->
      Option.map
        (fun op -> ImportedOption op)
        (option_op_of_source_name source_name)
  | Some Result ->
      Option.map
        (fun op -> ImportedResult op)
        (result_op_of_source_name source_name)
  | None -> None

let builtin_call_of_source_name source_name =
  if String.equal source_name Source.to_string then Some BuiltinToString
  else
    match source_name with
    | name
      when List.exists (String.equal name)
             [
               Source.length;
               Source.list_length_builtin;
               Source.dict_length_builtin;
             ] ->
        Some BuiltinLength
    | _ -> None

let trait_call_of_source ~trait_name ~method_name =
  if
    String.equal trait_name Source.stringable_trait
    && String.equal method_name Source.to_string
  then Some TraitStringableToString
  else if
    String.equal trait_name Source.has_length_trait
    && String.equal method_name Source.length
  then Some TraitHasLengthLength
  else None

let constructor_of_source ~parent_type ~constructor_name =
  match (parent_type, constructor_name) with
  | parent, name
    when String.equal parent Source.option_type
         && String.equal name Source.some_constructor ->
      Some OptionSomeConstructor
  | parent, name
    when String.equal parent Source.option_type
         && String.equal name Source.none_constructor ->
      Some OptionNoneConstructor
  | parent, name
    when String.equal parent Source.result_type
         && String.equal name Source.ok_constructor ->
      Some ResultOkConstructor
  | parent, name
    when String.equal parent Source.result_type
         && String.equal name Source.err_constructor ->
      Some ResultErrConstructor
  | _ -> None

let imported_unsupported_form ~module_path ~source_name =
  Printf.sprintf "imported function call '%s.%s'" module_path source_name

let imported_call_unsupported_form imported_call ~source_name =
  imported_unsupported_form
    ~module_path:(module_path_of_imported_call imported_call)
    ~source_name

let builtin_unsupported_form source_name =
  Printf.sprintf "builtin function call '%s'" source_name
