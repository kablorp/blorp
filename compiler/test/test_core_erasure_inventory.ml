(** Tests for [Core_erasure_inventory].

    The inventory is deliberately observational: it does not fail the pipeline.
    It gives ABI work a precise list of the remaining erased storage boundaries
    so later changes can make those states impossible one category at a time. *)

open Blorp
open Blorp.Ast
open Blorp.Core
module I = Blorp.Core_erasure_inventory

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty name = TyNamed (name, [])
let ty_int = ty "Int"
let ty_string = ty "String"
let ty_void = ty "Void"
let option_ty payload = TyNamed ("Option", [ payload ])
let list_ty elem = TyNamed ("List", [ elem ])
let mk desc ty = { desc; ty; loc }
let value name ty = mk (CVar (Var.named name)) ty

let box_op ?(kind = BoxPrim) source_ty =
  {
    box_value = value "v" source_ty;
    box_source_ty = source_ty;
    box_kind = kind;
  }

let boxed ?kind source_ty =
  {
    bsv_box = box_op ?kind source_ty;
    bsv_needs_release = false;
    bsv_transfers_ownership = false;
  }

let mk_simple_func ?(kind = CFUser) ?body name =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = [];
    cf_params = [];
    cf_return_ty = ty_void;
    cf_body = body;
    cf_is_pure = false;
    cf_kind = kind;
    cf_def_id = 0;
  }

let mk_prog decls =
  List.map (fun d -> { cd_desc = d; cd_loc = loc; cd_doc = None }) decls

let collect_expr ?(reg = Codegen_types.create_registry ()) expr =
  I.collect_program ~reg (mk_prog [ CDFunc (mk_simple_func ~body:expr "main") ])

let severity_name = function
  | I.ExplicitBoundary -> "explicit"
  | I.ManagedPointerErasure -> "managed-pointer"
  | I.MonomorphicValueErasure -> "monomorphic-value"
  | I.UnknownLayout -> "unknown-layout"

let expect_site label kind severity ty sites =
  match
    List.find_opt
      (fun (site : I.site) ->
        site.kind = kind && site.severity = severity
        && Types.types_equal site.ty ty)
      sites
  with
  | Some _ -> ()
  | None ->
      let rendered =
        sites |> List.map I.site_to_string |> String.concat "\n  "
      in
      Alcotest.failf "%s: missing %s/%s/%s site. Existing sites:\n  %s" label
        (I.site_kind_to_string kind)
        (severity_name severity) (Types.type_to_string ty) rendered

let reject_site_kind label kind sites =
  match List.find_opt (fun (site : I.site) -> site.kind = kind) sites with
  | None -> ()
  | Some site ->
      Alcotest.failf "%s: unexpected site %s" label (I.site_to_string site)

let test_boxed_stack_option_is_monomorphic_value_erasure () =
  let maybe_int = option_ty ty_int in
  let expr = mk (CBoxTyped (box_op maybe_int)) (ty "Ptr") in
  let sites = collect_expr expr in
  expect_site "box Option[Int]" I.BoxToErasedStorage I.MonomorphicValueErasure
    maybe_int sites

let test_boxed_managed_payload_is_managed_pointer_erasure () =
  let expr = mk (CBoxTyped (box_op ~kind:BoxPointer ty_string)) (ty "Ptr") in
  let sites = collect_expr expr in
  expect_site "box String" I.BoxToErasedStorage I.ManagedPointerErasure
    ty_string sites

let test_generic_erasure_is_explicit_boundary () =
  let generic_ty = TyVar "T" in
  let expr = mk (CBoxTyped (box_op generic_ty)) (ty "Ptr") in
  let sites = collect_expr expr in
  expect_site "box T" I.BoxToErasedStorage I.ExplicitBoundary generic_ty sites

let test_symbolic_dim_range_option_is_not_generic_erasure () =
  let maybe_range = option_ty (TyRange (TyVar "#N")) in
  let expr = mk (CBoxTyped (box_op maybe_range)) (ty "Ptr") in
  let sites = collect_expr expr in
  expect_site "box Option[..#N]" I.BoxToErasedStorage I.MonomorphicValueErasure
    maybe_range sites

let test_pointer_list_of_stack_option_is_inventory_gap () =
  let maybe_int = option_ty ty_int in
  let expr =
    mk
      (CListConstruct
         {
           lc_layout = list_pointer_storage ();
           lc_elems = [];
           lc_elem_needs_release = true;
         })
      (list_ty maybe_int)
  in
  let sites = collect_expr expr in
  expect_site "List[Option[Int]]" I.ListPointerElementStorage
    I.MonomorphicValueErasure maybe_int sites

let test_inline_list_of_int_is_not_erased_storage () =
  let expr =
    mk
      (CListConstruct
         {
           lc_layout = list_inline_storage InlineBytes8;
           lc_elems = [];
           lc_elem_needs_release = false;
         })
      (list_ty ty_int)
  in
  reject_site_kind "List[Int]" I.ListPointerElementStorage (collect_expr expr)

let test_erased_container_payload_sites_are_cataloged () =
  let maybe_int = option_ty ty_int in
  let tuple_expr =
    mk
      (CTupleConstruct
         {
           tc_elems = [ boxed maybe_int ];
           tc_release_mask = 0;
           tc_retain_mask = 0;
         })
      (TyTuple [ maybe_int ])
  in
  let record_expr =
    mk
      (CRecordConstruct
         {
           rc_type_name = "Box";
           rc_fields = [ RecordErasedField ("payload", boxed maybe_int) ];
           rc_erased_release_mask = Some 0;
         })
      (ty "Box")
  in
  let union_expr =
    mk
      (CUnionConstruct
         {
           uc_type_name = "MaybeBox";
           uc_constructor_name = "SomeBox";
           uc_c_name = "MaybeBox_SomeBox";
           uc_tag = 1;
           uc_representation = GenericUnion;
           uc_args = [ boxed maybe_int ];
           uc_release_mask = 0;
         })
      (ty "MaybeBox")
  in
  let body =
    mk (CSeq (tuple_expr, mk (CSeq (record_expr, union_expr)) ty_void)) ty_void
  in
  let sites = collect_expr body in
  expect_site "tuple field" (I.TupleField 0) I.MonomorphicValueErasure maybe_int
    sites;
  expect_site "record field" (I.RecordErasedField "payload")
    I.MonomorphicValueErasure maybe_int sites;
  expect_site "union payload"
    (I.UnionPayload ("SomeBox", 0))
    I.MonomorphicValueErasure maybe_int sites

let test_closure_capture_and_abi_sites_are_cataloged () =
  let maybe_int = option_ty ty_int in
  let create_expr =
    mk
      (CClosureCreate
         {
           cc_func = "lambda";
           cc_def_id = 1;
           cc_captures = [ ("m", maybe_int) ];
         })
      (TyFunc { params = [ maybe_int ]; return = maybe_int; is_pure = true })
  in
  let closure_abi =
    {
      ca_params = [ (Var.named "arg", maybe_int) ];
      ca_captures = [ ("captured", maybe_int) ];
      ca_task_abi = false;
    }
  in
  let prog =
    mk_prog
      [
        CDFunc (mk_simple_func ~body:create_expr "main");
        CDFunc (mk_simple_func ~kind:(CFClosureBody closure_abi) "lambda");
      ]
  in
  let sites = I.collect_program ~reg:(Codegen_types.create_registry ()) prog in
  expect_site "closure create capture" (I.ClosureCapture "m")
    I.MonomorphicValueErasure maybe_int sites;
  expect_site "closure ABI param" (I.ClosureParam "arg")
    I.MonomorphicValueErasure maybe_int sites;
  expect_site "closure ABI capture" (I.ClosureCapture "captured")
    I.MonomorphicValueErasure maybe_int sites

let suite =
  [
    ( "inventory",
      [
        Alcotest.test_case "boxed stack option" `Quick
          test_boxed_stack_option_is_monomorphic_value_erasure;
        Alcotest.test_case "boxed managed payload" `Quick
          test_boxed_managed_payload_is_managed_pointer_erasure;
        Alcotest.test_case "generic erasure" `Quick
          test_generic_erasure_is_explicit_boundary;
        Alcotest.test_case "symbolic dim range option" `Quick
          test_symbolic_dim_range_option_is_not_generic_erasure;
        Alcotest.test_case "pointer list stack option" `Quick
          test_pointer_list_of_stack_option_is_inventory_gap;
        Alcotest.test_case "inline list is not erased" `Quick
          test_inline_list_of_int_is_not_erased_storage;
        Alcotest.test_case "container payload sites" `Quick
          test_erased_container_payload_sites_are_cataloged;
        Alcotest.test_case "closure sites" `Quick
          test_closure_capture_and_abi_sites_are_cataloged;
      ] );
  ]
