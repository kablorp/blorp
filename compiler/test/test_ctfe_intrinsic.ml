(** Unit tests for CTFE intrinsic admission facts. *)

module I = Blorp.Ctfe_intrinsic

let check_opt label expected actual =
  Alcotest.(check bool) label true (actual = expected)

let check_string label expected actual =
  Alcotest.(check string) label expected actual

let test_list_operation_classification () =
  check_opt "list map" (Some I.ListMap) (I.list_op_of_source_name I.Source.map);
  check_opt "list length" (Some I.ListLength)
    (I.list_op_of_source_name I.Source.length);
  check_opt "unknown list op" None (I.list_op_of_source_name "missing")

let test_dict_operation_classification () =
  check_opt "dict from_list" (Some I.DictFromList)
    (I.dict_op_of_source_name I.Source.from_list);
  check_opt "dict get_or" (Some I.DictGetOr)
    (I.dict_op_of_source_name I.Source.get_or);
  check_opt "unknown dict op" None (I.dict_op_of_source_name "missing")

let test_option_operation_classification () =
  check_opt "option to_result" (Some I.OptionToResult)
    (I.option_op_of_source_name I.Source.to_result);
  check_opt "option get_or_else" (Some I.OptionGetOrElse)
    (I.option_op_of_source_name I.Source.get_or_else);
  check_opt "unknown option op" None (I.option_op_of_source_name "missing")

let test_result_operation_classification () =
  check_opt "result from_option" (Some I.ResultFromOption)
    (I.result_op_of_source_name I.Source.from_option);
  check_opt "result map_err" (Some I.ResultMapErr)
    (I.result_op_of_source_name I.Source.map_err);
  check_opt "unknown result op" None (I.result_op_of_source_name "missing")

let test_string_operation_classification () =
  check_opt "string substring" (Some I.StringSubstring)
    (I.string_op_of_source_name I.Source.substring);
  check_opt "string repeat" (Some I.StringRepeat)
    (I.string_op_of_source_name I.Source.repeat);
  check_opt "string split" (Some I.StringSplit)
    (I.string_op_of_source_name I.Source.split);
  check_opt "string replace" (Some I.StringReplace)
    (I.string_op_of_source_name I.Source.replace);
  check_opt "string trim" (Some I.StringTrim)
    (I.string_op_of_source_name I.Source.trim);
  check_opt "string get" (Some I.StringGet)
    (I.string_op_of_source_name I.Source.get);
  check_opt "string from_chars" (Some I.StringFromChars)
    (I.string_op_of_source_name I.Source.from_chars);
  check_opt "unknown string op" None (I.string_op_of_source_name "missing")

let test_imported_call_classification () =
  check_opt "imported list map" (Some (I.ImportedList I.ListMap))
    (I.imported_call_of_source ~module_path:I.Source.list_module
       ~source_name:I.Source.map);
  check_opt "imported dict get" (Some (I.ImportedDict I.DictGet))
    (I.imported_call_of_source ~module_path:I.Source.dict_module
       ~source_name:I.Source.get);
  check_opt "imported option map" (Some (I.ImportedOption I.OptionMap))
    (I.imported_call_of_source ~module_path:I.Source.option_module
       ~source_name:I.Source.map);
  check_opt "imported result map" (Some (I.ImportedResult I.ResultMap))
    (I.imported_call_of_source ~module_path:I.Source.result_module
       ~source_name:I.Source.map);
  check_opt "imported string repeat" (Some (I.ImportedString I.StringRepeat))
    (I.imported_call_of_source ~module_path:I.Source.string_module
       ~source_name:I.Source.repeat);
  check_opt "imported string trim" (Some (I.ImportedString I.StringTrim))
    (I.imported_call_of_source ~module_path:I.Source.string_module
       ~source_name:I.Source.trim);
  check_opt "imported string split" (Some (I.ImportedString I.StringSplit))
    (I.imported_call_of_source ~module_path:I.Source.string_module
       ~source_name:I.Source.split);
  check_opt "unknown module" None
    (I.imported_call_of_source ~module_path:"std/time"
       ~source_name:I.Source.length);
  check_opt "unknown operation" None
    (I.imported_call_of_source ~module_path:I.Source.list_module
       ~source_name:"missing")

let test_imported_call_metadata () =
  let list_map = I.ImportedList I.ListMap in
  let dict_get = I.ImportedDict I.DictGet in
  let string_repeat = I.ImportedString I.StringRepeat in
  check_string "list module" I.Source.list_module
    (I.module_path_of_imported_call list_map);
  check_string "dict module" I.Source.dict_module
    (I.module_path_of_imported_call dict_get);
  check_string "string module" I.Source.string_module
    (I.module_path_of_imported_call string_repeat);
  check_string "unsupported form" "imported function call 'std/list.map'"
    (I.imported_call_unsupported_form list_map ~source_name:I.Source.map)

let test_builtin_call_classification () =
  check_opt "builtin to_string" (Some I.BuiltinToString)
    (I.builtin_call_of_source_name I.Source.to_string);
  check_opt "builtin length" (Some I.BuiltinLength)
    (I.builtin_call_of_source_name I.Source.length);
  check_opt "builtin get" (Some I.BuiltinGet)
    (I.builtin_call_of_source_name I.Source.get);
  check_opt "builtin from_char" (Some I.BuiltinStringFromChar)
    (I.builtin_call_of_source_name I.Source.from_char);
  check_opt "builtin chars" (Some I.BuiltinStringChars)
    (I.builtin_call_of_source_name I.Source.chars);
  check_opt "builtin from_chars" (Some I.BuiltinStringFromChars)
    (I.builtin_call_of_source_name I.Source.from_chars);
  check_opt "unknown builtin" None (I.builtin_call_of_source_name "missing")

let test_trait_call_classification () =
  check_opt "Stringable.to_string" (Some I.TraitStringableToString)
    (I.trait_call_of_source ~trait_name:I.Source.stringable_trait
       ~method_name:I.Source.to_string);
  check_opt "HasLength.length" (Some I.TraitHasLengthLength)
    (I.trait_call_of_source ~trait_name:I.Source.has_length_trait
       ~method_name:I.Source.length);
  check_opt "unknown trait method" None
    (I.trait_call_of_source ~trait_name:I.Source.stringable_trait
       ~method_name:"missing")

let test_constructor_classification () =
  check_opt "Option.Some" (Some I.OptionSomeConstructor)
    (I.constructor_of_source ~parent_type:I.Source.option_type
       ~constructor_name:I.Source.some_constructor);
  check_opt "Option.None" (Some I.OptionNoneConstructor)
    (I.constructor_of_source ~parent_type:I.Source.option_type
       ~constructor_name:I.Source.none_constructor);
  check_opt "Result.Ok" (Some I.ResultOkConstructor)
    (I.constructor_of_source ~parent_type:I.Source.result_type
       ~constructor_name:I.Source.ok_constructor);
  check_opt "Result.Err" (Some I.ResultErrConstructor)
    (I.constructor_of_source ~parent_type:I.Source.result_type
       ~constructor_name:I.Source.err_constructor);
  check_opt "wrong parent" None
    (I.constructor_of_source ~parent_type:I.Source.result_type
       ~constructor_name:I.Source.some_constructor);
  check_opt "unknown constructor" None
    (I.constructor_of_source ~parent_type:I.Source.option_type
       ~constructor_name:"Missing")

let suite =
  [
    ( "operation_classification",
      [
        Alcotest.test_case "list" `Quick test_list_operation_classification;
        Alcotest.test_case "dict" `Quick test_dict_operation_classification;
        Alcotest.test_case "option" `Quick test_option_operation_classification;
        Alcotest.test_case "result" `Quick test_result_operation_classification;
        Alcotest.test_case "string" `Quick test_string_operation_classification;
        Alcotest.test_case "imported call" `Quick
          test_imported_call_classification;
        Alcotest.test_case "imported call metadata" `Quick
          test_imported_call_metadata;
        Alcotest.test_case "builtin call" `Quick
          test_builtin_call_classification;
        Alcotest.test_case "trait call" `Quick test_trait_call_classification;
        Alcotest.test_case "constructor" `Quick test_constructor_classification;
      ] );
  ]
