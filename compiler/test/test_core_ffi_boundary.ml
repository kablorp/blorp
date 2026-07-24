open Blorp.Ast
open Blorp.Core

let loc = dummy_loc
let ty name args = TyNamed (name, args)
let param name ty = { cp_name = Var.named name; cp_ty = ty; cp_loc = loc }

let foreign_func ?(passing = ForeignDefaultArgs []) name params =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = [];
    cf_params = params;
    cf_return_ty = ty "Void" [];
    cf_body = None;
    cf_is_pure = false;
    cf_kind =
      CFForeign
        {
          c_name = "c_" ^ name;
          includes = [];
          link_flags = [];
          arg_passing = passing;
        };
    cf_def_id = 0;
  }

let decl desc = { cd_desc = desc; cd_loc = loc; cd_doc = None }

let annotated_kind func =
  let prog = [ decl (CDFunc func) ] in
  let reg = Blorp.Codegen_types.create_registry () in
  let prog = Blorp.Core_ffi_boundary.annotate_program ~reg prog in
  match prog with
  | [ { cd_desc = CDFunc { cf_kind; _ }; _ } ] -> cf_kind
  | _ -> Alcotest.fail "expected one function"

let test_default_args_are_attached_to_core () =
  let func =
    foreign_func "mix"
      [
        param "s" (ty "String" []);
        param "n" (ty "Int" []);
        param "b" (ty "Bytes" []);
      ]
  in
  match annotated_kind func with
  | CFForeign { arg_passing; _ } ->
      Alcotest.(check bool)
        "per-arg default policy" true
        (arg_passing
        = ForeignDefaultArgs
            [
              ForeignDefensiveCopy ForeignStringCopy;
              ForeignScalarByValue;
              ForeignDefensiveCopy ForeignBytesCopy;
            ])
  | _ -> Alcotest.fail "expected CFForeign"

let test_borrow_boundary_remains_borrow () =
  let func =
    foreign_func ~passing:ForeignBorrowArgs "borrow"
      [ param "s" (ty "String" []) ]
  in
  match annotated_kind func with
  | CFForeign { arg_passing; _ } ->
      Alcotest.(check bool)
        "borrow policy unchanged" true
        (arg_passing = ForeignBorrowArgs)
  | _ -> Alcotest.fail "expected CFForeign"

let test_default_managed_arg_rejected_before_codegen () =
  let variant =
    {
      variant_name = "Message";
      variant_fields = [ ty "String" [] ];
      variant_tag = 0;
      variant_loc = loc;
      variant_def_id = None;
    }
  in
  let union =
    {
      type_name = "Message";
      type_params = [];
      type_variants = [ variant ];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
    }
  in
  let func = foreign_func "take_message" [ param "m" (ty "Message" []) ] in
  let prog = [ decl (CDType union); decl (CDFunc func) ] in
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Core_registry.register_types reg prog;
  try
    let _ = Blorp.Core_ffi_boundary.annotate_program ~reg prog in
    Alcotest.fail "expected managed default FFI arg to be rejected"
  with Blorp.Core_error.Core_error _ -> ()

let suite =
  [
    ( "annotate_program",
      [
        Alcotest.test_case "attaches per-arg default policy" `Quick
          test_default_args_are_attached_to_core;
        Alcotest.test_case "leaves borrow boundary unchanged" `Quick
          test_borrow_boundary_remains_borrow;
        Alcotest.test_case "rejects managed default args before codegen" `Quick
          test_default_managed_arg_rejected_before_codegen;
      ] );
  ]
