(** Tests for Core_mono — monomorphization pass. *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_string = TyNamed ("String", [])
let ty_bool = TyNamed ("Bool", [])

let tparams names =
  List.map
    (fun name -> Blorp.Generic_params.make_bound_type_param name [])
    names

let mk d t = { desc = d; ty = t; loc }

let ast_with_type expr ty =
  Blorp.Ast.with_expr_type_info expr (Test_helpers.expr_type_info_from_type ty)

let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int

let cstr s =
  mk (CLit (LitString (s, { sf_multiline = false; sf_raw = false }))) ty_string

let cvar n t = mk (CVar (Var.named n)) t

let clist elems =
  CList { ll_layout = list_pointer_storage (); ll_elems = elems }

let contains_substring s needle =
  let nl = String.length needle and sl = String.length s in
  let rec find i =
    if i + nl > sl then false
    else if String.sub s i nl = needle then true
    else find (i + 1)
  in
  nl <= sl && find 0

let mk_func ?(type_params = []) ?(type_param_decls = []) ?(module_path = None)
    ?(def_id = 0) name params return_ty body : core_func =
  {
    cf_name = name;
    cf_type_params = type_param_decls @ tparams type_params;
    cf_module = module_path;
    cf_params =
      List.map
        (fun (n, ty) -> { cp_name = Var.named n; cp_ty = ty; cp_loc = loc })
        params;
    cf_return_ty = return_ty;
    cf_body = Some body;
    cf_is_pure = true;
    cf_kind = CFUser;
    cf_def_id = def_id;
  }

let mk_decl f = { cd_desc = CDFunc f; cd_loc = loc; cd_doc = None }

let mk_record_decl ?(type_params = []) ?(is_value = false) name fields :
    core_decl =
  {
    cd_desc =
      CDRecord
        {
          record_name = name;
          record_type_params = tparams type_params;
          record_fields =
            List.map
              (fun (field_name, field_type) ->
                { field_name; field_type; field_loc = loc })
              fields;
          record_is_value = is_value;
          record_is_builtin = false;
        };
    cd_loc = loc;
    cd_doc = None;
  }

let mk_type_decl ?(type_params = []) name variants : core_decl =
  {
    cd_desc =
      CDType
        {
          type_name = name;
          type_params = tparams type_params;
          type_variants =
            List.mapi
              (fun tag (variant_name, variant_fields) ->
                {
                  variant_name;
                  variant_fields;
                  variant_tag = tag;
                  variant_loc = loc;
                  variant_def_id = Some (1000 + tag);
                })
              variants;
          type_is_enum = false;
          type_is_builtin = false;
          type_is_resource = false;
          type_resource_cleanup = None;
        };
    cd_loc = loc;
    cd_doc = None;
  }

let mk_impl trait_name for_type methods =
  {
    cd_desc =
      CDImpl
        { ci_trait = trait_name; ci_for_type = for_type; ci_methods = methods };
    cd_loc = loc;
    cd_doc = None;
  }

(* A fresh empty registry for each [collect_subst] test — keeps tests
   isolated from one another and avoids any shared mutable state. *)
let empty_reg () = Blorp.Codegen_types.create_registry ()
let st ty = Blorp.Core_mono.SubstType ty
let sd dims = Blorp.Core_mono.SubstDimPack dims

(* ============================================================================
   Type substitution utilities
   ============================================================================ *)

let test_collect_subst_simple () =
  let subst =
    Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) (tparams [ "T" ])
      (TyVar "T") ty_int []
  in
  Alcotest.(check int) "one binding" 1 (List.length subst);
  Alcotest.(check string) "binds T" "T" (fst (List.hd subst))

let test_collect_subst_nested () =
  let subst =
    Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) (tparams [ "T" ])
      (TyNamed ("List", [ TyVar "T" ]))
      (TyNamed ("List", [ ty_int ]))
      []
  in
  Alcotest.(check int) "one binding" 1 (List.length subst);
  Alcotest.(check string) "binds T" "T" (fst (List.hd subst))

let test_collect_subst_two_params () =
  let subst =
    Blorp.Core_mono.collect_subst ~reg:(empty_reg ())
      (tparams [ "A"; "B" ])
      (TyTuple [ TyVar "A"; TyVar "B" ])
      (TyTuple [ ty_int; ty_string ])
      []
  in
  let deduped = Blorp.Core_mono.dedup_subst_consistent subst in
  match deduped with
  | Some deduped -> Alcotest.(check int) "two bindings" 2 (List.length deduped)
  | None -> Alcotest.fail "expected consistent substitution"

let test_dedup_subst_consistent_rejects_conflict () =
  let subst =
    Blorp.Core_mono.dedup_subst_consistent
      [ ("T", st ty_int); ("T", st ty_string) ]
  in
  Alcotest.(check bool) "conflict rejected" true (subst = None)

let test_dedup_subst_consistent_refines_meta () =
  let list_meta = TyNamed ("List", [ TyMeta 13 ]) in
  let list_int = TyNamed ("List", [ ty_int ]) in
  let subst =
    Blorp.Core_mono.dedup_subst_consistent
      [ ("T", st list_meta); ("T", st list_int) ]
  in
  match subst with
  | Some [ ("T", Blorp.Core_mono.SubstType ty) ] ->
      Alcotest.(check bool) "meta refined to concrete" true (ty = list_int)
  | Some _ -> Alcotest.fail "expected one substitution"
  | None -> Alcotest.fail "expected meta/concrete pair to be consistent"

let test_dedup_subst_consistent_does_not_refine_rigid () =
  let subst =
    Blorp.Core_mono.dedup_subst_consistent
      [ ("T", st ty_int); ("T", st (TyVar "Outer")) ]
  in
  match subst with
  | Some [ ("T", Blorp.Core_mono.SubstType ty) ] ->
      Alcotest.(check bool)
        "rigid var remains open" false
        (Blorp.Core_mono.is_concrete_subst [ ("T", st ty) ])
  | Some _ -> Alcotest.fail "expected one substitution"
  | None -> Alcotest.fail "expected rigid/concrete pair to stay unresolved"

let test_collect_subst_erases_range_refinements () =
  let subst =
    Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) (tparams [ "T" ])
      (TyNamed ("List", [ TyVar "T" ]))
      (TyNamed ("List", [ TyTuple [ TyRange (TyConstInt 10); ty_int ] ]))
      []
  in
  let deduped = Blorp.Core_mono.dedup_subst_consistent subst in
  match deduped with
  | Some [ ("T", Blorp.Core_mono.SubstType (TyTuple [ elem; ty ])) ] ->
      Alcotest.(check bool) "range element erased to Int" true (elem = ty_int);
      Alcotest.(check bool) "other tuple element preserved" true (ty = ty_int)
  | Some _ -> Alcotest.fail "expected one tuple substitution"
  | None -> Alcotest.fail "expected range refinement to be consistent"

let test_collect_subst_ignores_erased_dim_value_params () =
  let type_params = tparams [ "T"; "#N"; "#M" ] in
  let raw =
    []
    |> Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) type_params (TyVar "T")
         ty_int
    |> Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) type_params
         (TyVar "#N") ty_int
    |> Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) type_params
         (TyVar "#M") ty_int
    |> Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) type_params
         (TyArray (TyVar "T", [ TyVar "#N"; TyVar "#M" ]))
         (TyArray (ty_int, [ TyConstInt 2; TyConstInt 3 ]))
  in
  match Blorp.Core_mono.dedup_subst_consistent raw with
  | Some subst ->
      Alcotest.(check bool)
        "T from value/return" true
        (List.assoc_opt "T" subst = Some (st ty_int));
      Alcotest.(check bool)
        "#N from return dimension" true
        (List.assoc_opt "#N" subst = Some (st (TyConstInt 2)));
      Alcotest.(check bool)
        "#M from return dimension" true
        (List.assoc_opt "#M" subst = Some (st (TyConstInt 3)))
  | None -> Alcotest.fail "plain Int value params should not bind dim vars"

let test_collect_subst_variadic_dim_packs () =
  let type_params = tparams [ "#As"; "#Bs" ] in
  let array dims = TyArray (ty_int, dims) in
  let raw =
    []
    |> Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) type_params
         (array [ TyVarDims "#As" ])
         (array [ TyConstInt 3 ])
    |> Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) type_params
         (array [ TyVarDims "#Bs" ])
         (array [ TyConstInt 2; TyConstInt 4 ])
  in
  match Blorp.Core_mono.dedup_subst_consistent raw with
  | Some subst ->
      Alcotest.(check bool)
        "#As captures one dimension" true
        (List.assoc_opt "#As" subst = Some (sd [ TyConstInt 3 ]));
      Alcotest.(check bool)
        "#Bs captures two dimensions" true
        (List.assoc_opt "#Bs" subst = Some (sd [ TyConstInt 2; TyConstInt 4 ]));
      Alcotest.(check bool)
        "return type splices packs" true
        (Blorp.Core_mono.apply_subst subst
           (TyTuple [ array [ TyVarDims "#Bs" ]; array [ TyVarDims "#As" ] ])
        = TyTuple
            [ array [ TyConstInt 2; TyConstInt 4 ]; array [ TyConstInt 3 ] ]);
      Alcotest.(check (option string))
        "mangle encodes packs" (Some "swap_order__mono_Dims_3_Dims_2_4")
        (Blorp.Core_mono.mangle_name "swap_order" subst)
  | None -> Alcotest.fail "expected variadic dimension pack substitution"

let test_collect_subst_implicit_trailing_dim_pack () =
  let type_params = tparams [ "#N" ] in
  let param =
    TyArray (ty_int, [ TyVar "#N"; TyVarDims "#Ds" ])
  in
  let actual = TyArray (ty_int, [ TyConstInt 2; TyConstInt 3 ]) in
  let raw =
    Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) type_params param actual []
  in
  match Blorp.Core_mono.dedup_subst_consistent raw with
  | Some subst ->
      Alcotest.(check bool)
        "declared prefix dimension binds" true
        (List.assoc_opt "#N" subst = Some (st (TyConstInt 2)));
      Alcotest.(check bool)
        "implicit trailing pack captures suffix" true
        (List.assoc_opt "#Ds" subst = Some (sd [ TyConstInt 3 ]));
      Alcotest.(check bool)
        "return type splices implicit trailing pack" true
        (Blorp.Core_mono.apply_subst subst param = actual)
  | None -> Alcotest.fail "expected implicit trailing dimension pack substitution"

let test_collect_subst_ignores_identity_bindings () =
  let dict key value = TyNamed ("Dict", [ key; value ]) in
  let type_params = tparams [ "K"; "V" ] in
  let raw =
    []
    |> Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) type_params
         (dict (TyVar "K") (TyVar "V"))
         (dict (TyNamed ("K", [])) (TyNamed ("V", [])))
    |> Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) type_params (TyVar "K")
         ty_string
    |> Blorp.Core_mono.collect_subst ~reg:(empty_reg ()) type_params (TyVar "V")
         ty_int
  in
  match Blorp.Core_mono.dedup_subst_consistent raw with
  | Some subst ->
      Alcotest.(check bool)
        "K resolved from sibling arg" true
        (List.assoc_opt "K" subst = Some (st ty_string));
      Alcotest.(check bool)
        "V resolved from sibling arg" true
        (List.assoc_opt "V" subst = Some (st ty_int))
  | None -> Alcotest.fail "identity bindings should not conflict with evidence"

let test_apply_subst () =
  let subst = [ ("T", st ty_int) ] in
  let result = Blorp.Core_mono.apply_subst subst (TyVar "T") in
  Alcotest.(check bool) "T → Int" true (result = ty_int)

let test_apply_subst_nested () =
  let subst = [ ("T", st ty_string) ] in
  let result =
    Blorp.Core_mono.apply_subst subst (TyNamed ("List", [ TyVar "T" ]))
  in
  Alcotest.(check bool)
    "List[T] → List[String]" true
    (result = TyNamed ("List", [ ty_string ]))

let test_subst_core_types_updates_loop_binder () =
  let subst = [ ("T", st ty_int) ] in
  let list_t = TyNamed ("List", [ TyVar "T" ]) in
  let body = mk CVoid (TyNamed ("Void", [])) in
  let loop =
    mk
      (CFor (loop_binder_named "elem" (TyVar "T"), cvar "items" list_t, body))
      (TyNamed ("Void", []))
  in
  let result = Blorp.Core_mono.subst_core_types subst loop in
  match result.desc with
  | CFor ({ loop_ty; _ }, iter, _) ->
      Alcotest.(check bool) "binder type substituted" true (loop_ty = ty_int);
      Alcotest.(check bool)
        "iter type substituted" true
        (iter.ty = TyNamed ("List", [ ty_int ]))
  | _ -> Alcotest.fail "expected CFor"

(* ============================================================================
   Name mangling
   ============================================================================ *)

let test_mangle_simple () =
  let result = Blorp.Core_mono.mangle_name "identity" [ ("T", st ty_int) ] in
  Alcotest.(check (option string)) "mangled" (Some "identity__mono_Int") result

let test_mangle_two_params () =
  let result =
    Blorp.Core_mono.mangle_name "pair" [ ("A", st ty_int); ("B", st ty_string) ]
  in
  Alcotest.(check (option string))
    "mangled" (Some "pair__mono_Int_String") result

let test_mangle_container () =
  let result =
    Blorp.Core_mono.mangle_name "process"
      [ ("T", st (TyNamed ("List", [ ty_int ]))) ]
  in
  Alcotest.(check (option string))
    "mangled" (Some "process__mono_List_Int") result

(* ============================================================================
   Full monomorphization
   ============================================================================ *)

let test_mono_simple () =
  (* func identity[T](x: T) -> T: x
     func main(): identity(42) *)
  let identity =
    mk_func ~type_params:[ "T" ] "identity"
      [ ("x", TyVar "T") ]
      (TyVar "T") (cvar "x" (TyVar "T"))
  in
  let fty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } in
  let main_body =
    mk (CCall (CKUnknown, cvar "identity" fty, [ cint 42 ])) ty_int
  in
  let main_fn = mk_func "main" [] ty_int main_body in
  let prog = [ mk_decl identity; mk_decl main_fn ] in
  let result = Blorp.Core_mono.monomorphize_program prog in
  let names =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "has specialized" true
    (List.mem "identity__mono_Int" names);
  Alcotest.(check bool) "has original" true (List.mem "identity" names)

let test_mono_call_rewritten () =
  let identity =
    mk_func ~type_params:[ "T" ] "identity"
      [ ("x", TyVar "T") ]
      (TyVar "T") (cvar "x" (TyVar "T"))
  in
  let fty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } in
  let main_body =
    mk (CCall (CKUnknown, cvar "identity" fty, [ cint 42 ])) ty_int
  in
  let main_fn = mk_func "main" [] ty_int main_body in
  let prog = [ mk_decl identity; mk_decl main_fn ] in
  let result = Blorp.Core_mono.monomorphize_program prog in
  let main_decl =
    List.find
      (fun d ->
        match d.cd_desc with CDFunc f -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc { cf_body = Some body; _ } -> (
      match body.desc with
      | CCall (_, { desc = CVar v; _ }, _) ->
          Alcotest.(check string) "call rewritten" "identity__mono_Int" v.vname
      | _ -> Alcotest.fail "expected CCall")
  | _ -> Alcotest.fail "expected CDFunc"

let test_mono_specialized_types () =
  let identity =
    mk_func ~type_params:[ "T" ] "identity"
      [ ("x", TyVar "T") ]
      (TyVar "T") (cvar "x" (TyVar "T"))
  in
  let fty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } in
  let main_body =
    mk (CCall (CKUnknown, cvar "identity" fty, [ cint 42 ])) ty_int
  in
  let main_fn = mk_func "main" [] ty_int main_body in
  let prog = [ mk_decl identity; mk_decl main_fn ] in
  let result = Blorp.Core_mono.monomorphize_program prog in
  let spec =
    List.find
      (fun d ->
        match d.cd_desc with
        | CDFunc f -> f.cf_name = "identity__mono_Int"
        | _ -> false)
      result
  in
  match spec.cd_desc with
  | CDFunc f ->
      Alcotest.(check bool) "no type params" true (f.cf_type_params = []);
      Alcotest.(check bool) "return is Int" true (f.cf_return_ty = ty_int);
      let param_ty = (List.hd f.cf_params).cp_ty in
      Alcotest.(check bool) "param is Int" true (param_ty = ty_int)
  | _ -> Alcotest.fail "expected CDFunc"

let test_mono_no_generics_unchanged () =
  let f =
    mk_func "add"
      [ ("a", ty_int); ("b", ty_int) ]
      ty_int
      (mk (CBin (Add, cvar "a" ty_int, cvar "b" ty_int)) ty_int)
  in
  let prog = [ mk_decl f ] in
  let result = Blorp.Core_mono.monomorphize_program prog in
  Alcotest.(check int) "unchanged" 1 (List.length result)

let test_mono_materializes_generic_record_layout_without_generic_functions () =
  let box_string_ty = TyNamed ("Box", [ ty_string ]) in
  let read_body = mk (CField (cvar "box" box_string_ty, "value")) ty_string in
  let read_fn = mk_func "read" [ ("box", box_string_ty) ] ty_string read_body in
  let result =
    Blorp.Core_mono.monomorphize_program
      [
        mk_record_decl ~type_params:[ "T" ] "Box" [ ("value", TyVar "T") ];
        mk_decl read_fn;
      ]
  in
  let concrete_record =
    List.find_opt
      (function
        | { cd_desc = CDRecord r; _ } -> r.record_name = "Box__mono_String"
        | _ -> false)
      result
  in
  let read_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "read" | _ -> false)
      result
  in
  (match concrete_record with
  | Some { cd_desc = CDRecord r; _ } -> (
      Alcotest.(check bool)
        "concrete record has no type params" true
        (r.record_type_params = []);
      match r.record_fields with
      | [ { field_name = "value"; field_type; _ } ] ->
          Alcotest.(check bool)
            "field type is concrete" true (field_type = ty_string)
      | _ -> Alcotest.fail "expected one value field")
  | _ -> Alcotest.fail "expected generated concrete record");
  match read_decl.cd_desc with
  | CDFunc { cf_params = [ param ]; cf_body = Some body; _ } -> (
      Alcotest.(check bool)
        "function param uses concrete record type" true
        (param.cp_ty = TyNamed ("Box__mono_String", []));
      match body.desc with
      | CField (owner, "value") ->
          Alcotest.(check bool)
            "field owner uses concrete record type" true
            (owner.ty = TyNamed ("Box__mono_String", []))
      | _ -> Alcotest.fail "expected field access")
  | _ -> Alcotest.fail "expected read function"

let test_mono_materializes_generic_union_layout_without_generic_functions () =
  let choice_string_ty = TyNamed ("Choice", [ ty_string ]) in
  let body = cvar "choice" choice_string_ty in
  let pass_fn =
    mk_func "pass_choice" [ ("choice", choice_string_ty) ] choice_string_ty body
  in
  let reg = empty_reg () in
  let result =
    Blorp.Core_mono.monomorphize_program ~reg
      [
        mk_type_decl ~type_params:[ "T" ] "Choice"
          [ ("Picked", [ TyVar "T" ]); ("Empty", []) ];
        mk_decl pass_fn;
      ]
  in
  let concrete_type =
    List.find_opt
      (function
        | { cd_desc = CDType t; _ } -> t.type_name = "Choice__mono_String"
        | _ -> false)
      result
  in
  let pass_decl =
    List.find
      (function
        | { cd_desc = CDFunc f; _ } -> f.cf_name = "pass_choice" | _ -> false)
      result
  in
  (match concrete_type with
  | Some { cd_desc = CDType t; _ } -> (
      Alcotest.(check bool)
        "concrete union has no type params" true (t.type_params = []);
      Alcotest.(check bool)
        "ordinary concrete union uses typed payload storage" true
        (Blorp.Codegen_types.union_uses_typed_payload_storage reg
           "Choice__mono_String");
      match t.type_variants with
      | [
       {
         variant_name = "Picked";
         variant_fields = [ field_ty ];
         variant_def_id;
         _;
       };
       { variant_name = "Empty"; variant_fields = []; _ };
      ] ->
          Alcotest.(check bool)
            "payload type is concrete" true (field_ty = ty_string);
          Alcotest.(check bool)
            "concrete variant gets fresh identity" true
            (variant_def_id <> Some 1000)
      | _ -> Alcotest.fail "expected Picked(String) and Empty variants")
  | _ -> Alcotest.fail "expected generated concrete union");
  match pass_decl.cd_desc with
  | CDFunc { cf_params = [ param ]; cf_return_ty; cf_body = Some body; _ } ->
      Alcotest.(check bool)
        "function param uses concrete union type" true
        (param.cp_ty = TyNamed ("Choice__mono_String", []));
      Alcotest.(check bool)
        "function return uses concrete union type" true
        (cf_return_ty = TyNamed ("Choice__mono_String", []));
      Alcotest.(check bool)
        "body uses concrete union type" true
        (body.ty = TyNamed ("Choice__mono_String", []))
  | _ -> Alcotest.fail "expected pass_choice function"

let test_mono_keeps_runtime_erased_bridge_union_payload_storage () =
  let attempt_int_ty = TyNamed ("std_channel__RecvAttempt", [ ty_int ]) in
  let body = cvar "attempt" attempt_int_ty in
  let pass_fn =
    mk_func "pass_recv_attempt"
      [ ("attempt", attempt_int_ty) ]
      attempt_int_ty body
  in
  let reg = empty_reg () in
  let result =
    Blorp.Core_mono.monomorphize_program ~reg
      [
        mk_type_decl ~type_params:[ "T" ] "std_channel__RecvAttempt"
          [
            ("RecvValue", [ TyVar "T" ]);
            ("RecvWouldBlock", []);
            ("RecvSealed", []);
          ];
        mk_decl pass_fn;
      ]
  in
  let concrete_name = "std_channel__RecvAttempt__mono_Int" in
  let concrete_type =
    List.find_opt
      (function
        | { cd_desc = CDType t; _ } -> t.type_name = concrete_name | _ -> false)
      result
  in
  match concrete_type with
  | Some { cd_desc = CDType _; _ } ->
      Alcotest.(check bool)
        "runtime bridge union keeps erased payload storage" false
        (Blorp.Codegen_types.union_uses_typed_payload_storage reg concrete_name)
  | _ -> Alcotest.fail "expected generated concrete RecvAttempt union"

let test_mono_two_instantiations () =
  let identity =
    mk_func ~type_params:[ "T" ] "identity"
      [ ("x", TyVar "T") ]
      (TyVar "T") (cvar "x" (TyVar "T"))
  in
  let fty_int =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let fty_bool =
    TyFunc { params = [ ty_bool ]; return = ty_bool; is_pure = true }
  in
  let body =
    mk
      (CBin
         ( Add,
           mk (CCall (CKUnknown, cvar "identity" fty_int, [ cint 1 ])) ty_int,
           mk
             (CCall
                ( CKUnknown,
                  cvar "identity" fty_bool,
                  [ mk (CLit (LitBool true)) ty_bool ] ))
             ty_bool ))
      ty_int
  in
  let main_fn = mk_func "main" [] ty_int body in
  let prog = [ mk_decl identity; mk_decl main_fn ] in
  let result = Blorp.Core_mono.monomorphize_program prog in
  let names =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "has Int spec" true
    (List.mem "identity__mono_Int" names);
  Alcotest.(check bool)
    "has Bool spec" true
    (List.mem "identity__mono_Bool" names)

let test_mono_repeated_type_param_consistent_call_ok () =
  let same =
    mk_func ~type_params:[ "T" ] "same"
      [ ("a", TyVar "T"); ("b", TyVar "T") ]
      (TyVar "T") (cvar "a" (TyVar "T"))
  in
  let fty =
    TyFunc { params = [ ty_int; ty_int ]; return = ty_int; is_pure = true }
  in
  let main_body =
    mk (CCall (CKUnknown, cvar "same" fty, [ cint 1; cint 2 ])) ty_int
  in
  let main_fn = mk_func "main" [] ty_int main_body in
  let prog = [ mk_decl same; mk_decl main_fn ] in
  let result = Blorp.Core_mono.monomorphize_program prog in
  let names =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "has Int specialization" true
    (List.mem "same__mono_Int" names);
  let main_decl =
    List.find
      (fun d ->
        match d.cd_desc with CDFunc f -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar v; _ }, _); _ }; _ } ->
      Alcotest.(check string) "call rewritten" "same__mono_Int" v.vname
  | _ -> Alcotest.fail "expected rewritten main call"

let test_mono_rejects_conflicting_repeated_type_param_call () =
  let same =
    mk_func ~type_params:[ "T" ] "same"
      [ ("a", TyVar "T"); ("b", TyVar "T") ]
      (TyVar "T") (cvar "a" (TyVar "T"))
  in
  let fty =
    TyFunc { params = [ ty_int; ty_string ]; return = ty_int; is_pure = true }
  in
  let main_body =
    mk (CCall (CKUnknown, cvar "same" fty, [ cint 1; cstr "x" ])) ty_int
  in
  let main_fn = mk_func "main" [] ty_int main_body in
  let prog = [ mk_decl same; mk_decl main_fn ] in
  let fired =
    try
      ignore (Blorp.Core_mono.monomorphize_program prog);
      false
    with Blorp.Core_error.Core_error { phase; msg; _ } ->
      phase = Blorp.Core_error.Stage Blorp.Core_stage.Mono
      && contains_substring msg "Conflicting type arguments"
      && contains_substring msg "same"
  in
  Alcotest.(check bool) "conflicting type arguments rejected" true fired

let test_mono_materializes_generic_trait_impl () =
  let a_param =
    Blorp.Generic_params.make_bound_type_param "A" [ "Stringable" ]
  in
  let b_param =
    Blorp.Generic_params.make_bound_type_param "B" [ "Stringable" ]
  in
  let tuple_ab = TyTuple [ TyBoundVar a_param; TyBoundVar b_param ] in
  let tuple_int_int = TyTuple [ ty_int; ty_int ] in
  let to_string_impl =
    mk_func ~type_param_decls:[ a_param; b_param ] "to_string"
      [ ("self", tuple_ab) ]
      ty_string (cstr "(...)")
  in
  let call_ty =
    TyFunc { params = [ tuple_int_int ]; return = ty_string; is_pure = true }
  in
  let pair_expr = mk (CTuple [ cint 1; cint 2 ]) tuple_int_int in
  let main_body =
    mk (CCall (CKUnknown, cvar "to_string" call_ty, [ pair_expr ])) ty_string
  in
  let main_fn = mk_func "main" [] ty_string main_body in
  let prog =
    [ mk_impl "Stringable" tuple_ab [ to_string_impl ]; mk_decl main_fn ]
  in
  let result = Blorp.Core_mono.monomorphize_program prog in
  let concrete_impls =
    List.filter_map
      (fun d ->
        match d.cd_desc with
        | CDImpl i
          when i.ci_trait = "Stringable" && i.ci_for_type = tuple_int_int ->
            Some i
        | _ -> None)
      result
  in
  Alcotest.(check int) "one concrete tuple impl" 1 (List.length concrete_impls);
  match (List.hd concrete_impls).ci_methods with
  | [ m ] ->
      Alcotest.(check bool)
        "method no longer generic" true (m.cf_type_params = []);
      Alcotest.(check bool)
        "param concrete" true
        ((List.hd m.cf_params).cp_ty = tuple_int_int)
  | _ -> Alcotest.fail "expected one impl method"

let test_mono_e2e_pipeline () =
  let mk_ast desc ty =
    ast_with_type
      {
        expr_desc = desc;
        expr_loc = loc;
        expr_type = None;
        expr_type_info = None;
        expr_rc = None;
      }
      ty
  in
  let x_param : param =
    {
      param_name = Some "x";
      param_pattern = None;
      param_type = Some (TyVar "T");
      param_loc = loc;
    }
  in
  let identity_body = mk_ast (EIdent "x") (TyVar "T") in
  let identity_func : func_decl =
    {
      func_name = Some "identity";
      func_type_params = [ Blorp.Ast.make_type_param "T" [] ];
      func_params = [ x_param ];
      func_return_type = Some (TyVar "T");
      func_body = FuncBodyExpr identity_body;
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  let call_expr =
    mk_ast
      (ECall
         ( mk_ast (EIdent "identity")
             (TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }),
           [ mk_ast (ELiteral (LitInt 42L)) ty_int ] ))
      ty_int
  in
  let compute_func : func_decl =
    {
      func_name = Some "compute";
      func_type_params = [];
      func_params = [];
      func_return_type = Some ty_int;
      func_body = FuncBodyExpr call_expr;
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  let program : program =
    [
      { decl_desc = DFunc identity_func; decl_loc = loc; decl_doc = None };
      { decl_desc = DFunc compute_func; decl_loc = loc; decl_doc = None };
    ]
  in
  let c_code = Test_helpers.compile_valid_program program in
  let contains sub =
    let n = String.length sub in
    let m = String.length c_code in
    let rec go i = i + n <= m && (String.sub c_code i n = sub || go (i + 1)) in
    go 0
  in
  Alcotest.(check bool)
    "has specialized func" true
    (contains "identity__mono_Int");
  Alcotest.(check bool) "has compute" true (contains "long compute(void)")

(* ============================================================================
   Call-site resolution: UFCS-mangled and module-scoped imports
   ============================================================================ *)

(** Regression for the post-cutover bug where UFCS-mangled call names were
    never enqueued for specialization. Uses [to_result] so [get_or] can be covered
    by the option-fusion regression below. *)
let test_mono_ufcs_mangled_callee () =
  (* generic body stored under its prefixed name: std_option__to_result *)
  let gf =
    mk_func ~type_params:[ "T"; "E" ] "std_option__to_result"
      [ ("self", TyNamed ("Option", [ TyVar "T" ])); ("error", TyVar "E") ]
      (TyNamed ("Result", [ TyVar "T"; TyVar "E" ]))
      (cvar "err_result" (TyNamed ("Result", [ TyVar "T"; TyVar "E" ])))
  in
  (* call site uses the UFCS-mangled form: __ufcs_std$option__to_result *)
  let ty_char = TyNamed ("Char", []) in
  let result_ty = TyNamed ("Result", [ ty_char; ty_string ]) in
  let fty =
    TyFunc
      {
        params = [ TyNamed ("Option", [ ty_char ]); ty_string ];
        return = result_ty;
        is_pure = true;
      }
  in
  let caller_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "__ufcs_std$option__to_result" fty,
           [
             cvar "opt" (TyNamed ("Option", [ ty_char ])); cvar "err" ty_string;
           ] ))
      result_ty
  in
  let caller =
    mk_func "caller"
      [ ("opt", TyNamed ("Option", [ ty_char ])); ("err", ty_string) ]
      result_ty caller_body
  in
  let prog = [ mk_decl gf; mk_decl caller ] in
  let result = Blorp.Core_mono.monomorphize_program prog in
  let names =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "has Char/String specialization" true
    (List.mem "std_option__to_result__mono_String_Char" names)

let test_mono_bare_call_prefers_selected_direct_kind_generic () =
  let impure_primary =
    mk_func ~def_id:701 ~type_params:[ "T" ] "apply"
      [ ("x", TyVar "T") ]
      (TyVar "T") (cvar "x" (TyVar "T"))
  in
  let pure_selected =
    mk_func ~def_id:702 ~type_params:[ "T" ] "apply__pure"
      [ ("x", TyVar "T") ]
      (TyVar "T") (cvar "x" (TyVar "T"))
  in
  let call_ty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let main_body =
    mk
      (CCall
         (CKSelectedDirect 702, cvar "apply" call_ty, [ cvar "value" ty_int ]))
      ty_int
  in
  let main_fn = mk_func "main" [ ("value", ty_int) ] ty_int main_body in
  let result =
    Blorp.Core_mono.monomorphize_program
      [ mk_decl impure_primary; mk_decl pure_selected; mk_decl main_fn ]
  in
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (kind, { desc = CVar v; _ }, _); _ }; _ }
    ->
      Alcotest.(check string)
        "selected generic target follows call kind id" "apply__pure__mono_Int"
        v.vname;
      Alcotest.(check bool)
        "selected kind is cleared after specialization" true
        (match kind with CKSelectedDirect _ -> false | _ -> true)
  | _ -> Alcotest.fail "expected rewritten main call"

let test_mono_qualified_call_prefers_selected_direct_kind_generic () =
  let list_t = TyNamed ("List", [ TyVar "T" ]) in
  let list_int = TyNamed ("List", [ ty_int ]) in
  let impure_primary =
    mk_func ~def_id:711 ~type_params:[ "T" ] ~module_path:(Some "std/list")
      "std_list__reverse"
      [ ("self", list_t) ]
      list_t (cvar "self" list_t)
  in
  let pure_selected =
    mk_func ~def_id:712 ~type_params:[ "T" ] ~module_path:(Some "std/list")
      "std_list__reverse__pure"
      [ ("self", list_t) ]
      list_t (cvar "self" list_t)
  in
  let call_ty =
    TyFunc { params = [ list_int ]; return = list_int; is_pure = true }
  in
  let module_alias = cvar "L" (TyNamed ("Module", [])) in
  let callee = mk (CField (module_alias, "reverse")) call_ty in
  let main_body =
    mk
      (CCall (CKSelectedDirect 712, callee, [ cvar "items" list_int ]))
      list_int
  in
  let main_fn = mk_func "main" [ ("items", list_int) ] list_int main_body in
  let import_aliases = Hashtbl.create 1 in
  Hashtbl.replace import_aliases "L" ("std/list", "");
  let result =
    Blorp.Core_mono.monomorphize_program ~import_aliases
      [ mk_decl impure_primary; mk_decl pure_selected; mk_decl main_fn ]
  in
  let names =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "emits selected module-owned pure overload specialization" true
    (List.mem "std_list__reverse__pure__mono_Int" names);
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (kind, { desc = CVar v; _ }, _); _ }; _ }
    ->
      Alcotest.(check string)
        "qualified selected generic target follows call kind id"
        "std_list__reverse__pure__mono_Int" v.vname;
      Alcotest.(check bool)
        "selected kind is cleared after specialization" true
        (match kind with CKSelectedDirect _ -> false | _ -> true)
  | _ -> Alcotest.fail "expected rewritten main call"

let test_mono_selected_registered_generic_builtin_is_specialized () =
  let list_t = TyNamed ("List", [ TyVar "T" ]) in
  let list_int = TyNamed ("List", [ ty_int ]) in
  let drop_builtin : core_func =
    {
      cf_name = "std_list__drop__pure";
      cf_module = Some "std/list";
      cf_type_params = tparams [ "T" ];
      cf_params =
        [
          { cp_name = Var.named "self"; cp_ty = list_t; cp_loc = loc };
          { cp_name = Var.named "count"; cp_ty = ty_int; cp_loc = loc };
        ];
      cf_return_ty = list_t;
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFBuiltin;
      cf_def_id = 713;
    }
  in
  let call_ty =
    TyFunc
      {
        params = [ list_int; ty_int ];
        return = list_int;
        is_pure = true;
      }
  in
  let main_body =
    mk
      (CCall
         ( CKSelectedDirect 713,
           cvar "std_list__drop__pure" call_ty,
           [ cvar "items" list_int; cint 1 ] ))
      list_int
  in
  let main_fn = mk_func "main" [ ("items", list_int) ] list_int main_body in
  let result =
    Blorp.Core_mono.monomorphize_program
      [ mk_decl drop_builtin; mk_decl main_fn ]
  in
  let names =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "retains and specializes referenced generic builtin" true
    (List.mem "std_list__drop__pure__mono_Int" names)

let test_mono_selected_direct_requires_matching_signature () =
  let list_t = TyNamed ("List", [ TyVar "T" ]) in
  let list_string = TyNamed ("List", [ ty_string ]) in
  let stale_generic =
    mk_func ~def_id:1652 ~type_params:[ "T" ] ~module_path:(Some "std/list")
      "std_list____unsafe_list_remove"
      [ ("self", list_t); ("index", ty_int) ]
      list_t (cvar "self" list_t)
  in
  let call_ty =
    TyFunc
      { params = [ ty_string; ty_string ]; return = list_string; is_pure = true }
  in
  let main_body =
    mk
      (CCall
         ( CKSelectedDirect 1652,
           cvar "std_string__split" call_ty,
           [ cvar "source" ty_string; cstr "\n" ] ))
      list_string
  in
  let main_fn =
    mk_func "main" [ ("source", ty_string) ] list_string main_body
  in
  let result =
    Blorp.Core_mono.monomorphize_program [ mk_decl stale_generic; mk_decl main_fn ]
  in
  let names =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "does not generate stale generic specialization" false
    (List.mem "std_list____unsafe_list_remove__mono_String" names);
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      {
        cf_body =
          Some
            {
              desc = CCall (CKSelectedDirect 1652, { desc = CVar v; _ }, _);
              _;
            };
        _;
      } ->
      Alcotest.(check string)
        "keeps current callee for later resolve" "std_string__split" v.vname
  | _ -> Alcotest.fail "expected unchanged selected call"

let test_mono_signature_guard_allows_dimension_params () =
  let vector_generic = TyArray (TyVar "T", [ TyVar "#N" ]) in
  let vector_int_3 = TyArray (ty_int, [ TyConstInt 3 ]) in
  let set_all =
    mk_func ~type_params:[ "T"; "#N" ] ~module_path:(Some "std/tensor")
      "std_tensor__set_all"
      [ ("arr", vector_generic); ("val", TyVar "T") ]
      vector_generic (cvar "arr" vector_generic)
  in
  let call_ty =
    TyFunc
      {
        params = [ vector_int_3; ty_int ];
        return = vector_int_3;
        is_pure = true;
      }
  in
  let main_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "__ufcs_std$tensor__set_all" call_ty,
           [ cvar "values" vector_int_3; cint 0 ] ))
      vector_int_3
  in
  let main_fn = mk_func "main" [ ("values", vector_int_3) ] vector_int_3 main_body in
  let result =
    Blorp.Core_mono.monomorphize_program [ mk_decl set_all; mk_decl main_fn ]
  in
  Alcotest.(check bool)
    "emits tensor specialization with dimension argument" true
    (List.exists
       (function
         | { cd_desc = CDFunc f; _ } ->
             contains_substring f.cf_name "std_tensor__set_all__mono"
         | _ -> false)
       result);
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar v; _ }, _); _ }; _ } ->
      Alcotest.(check bool)
        "rewrites UFCS tensor call to specialized callee" true
        (contains_substring v.vname "std_tensor__set_all__mono")
  | _ -> Alcotest.fail "expected rewritten main call"

let test_mono_signature_guard_allows_wildcard_dim_pack () =
  let tensor_any_rank = TyArray (TyVar "T", [ TyVarDims "#_" ]) in
  let vector_int_3 = TyArray (ty_int, [ TyConstInt 3 ]) in
  let is_empty =
    mk_func ~type_params:[ "T" ] ~module_path:(Some "std/tensor")
      "std_tensor__is_empty" [ ("arr", tensor_any_rank) ] ty_bool
      (mk (CLit (LitBool false)) ty_bool)
  in
  let call_ty =
    TyFunc { params = [ vector_int_3 ]; return = ty_bool; is_pure = true }
  in
  let main_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "std_tensor__is_empty" call_ty,
           [ cvar "values" vector_int_3 ] ))
      ty_bool
  in
  let main_fn = mk_func "main" [ ("values", vector_int_3) ] ty_bool main_body in
  let result =
    Blorp.Core_mono.monomorphize_program [ mk_decl is_empty; mk_decl main_fn ]
  in
  Alcotest.(check bool)
    "emits tensor wildcard-rank specialization" true
    (List.exists
       (function
         | { cd_desc = CDFunc f; _ } ->
             contains_substring f.cf_name "std_tensor__is_empty__mono_Int"
         | _ -> false)
       result);
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar v; _ }, _); _ }; _ } ->
      Alcotest.(check bool)
        "rewrites wildcard-rank tensor call to specialized callee" true
        (contains_substring v.vname "std_tensor__is_empty__mono_Int")
  | _ -> Alcotest.fail "expected rewritten main call"

let test_mono_prefixed_runtime_backed_call_resolves_without_mono () =
  let tensor_any = TyArray (TyVar "T", [ TyVarDims "#_" ]) in
  let tensor_int_3 = TyArray (ty_int, [ TyConstInt 3 ]) in
  let length_func : core_func =
    {
      cf_name = "std_tensor__length";
      cf_module = Some "std/tensor";
      cf_type_params = tparams [ "T" ];
      cf_params =
        [
          { cp_name = Var.named "arr"; cp_ty = tensor_any; cp_loc = loc };
        ];
      cf_return_ty = ty_int;
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFBuiltin;
      cf_def_id = 91;
    }
  in
  let call_ty =
    TyFunc { params = [ tensor_int_3 ]; return = ty_int; is_pure = true }
  in
  let body =
    mk
      (CCall
         ( CKUnknown,
           cvar "std_tensor__length" call_ty,
           [ cvar "values" tensor_int_3 ] ))
      ty_int
  in
  let caller =
    {
      (mk_func ~module_path:(Some "std/tensor") "std_tensor__uses_length"
         [ ("values", tensor_int_3) ]
         ty_int body)
      with
      cf_def_id = 92;
    }
  in
  ignore
    (Blorp.Core_mono.monomorphize_program [ mk_decl length_func; mk_decl caller ])

let test_mono_fuses_option_get_or_call () =
  let option_t = TyNamed ("Option", [ TyVar "T" ]) in
  let option_int = TyNamed ("Option", [ ty_int ]) in
  let gf =
    mk_func ~type_params:[ "T" ] ~module_path:(Some "std/option")
      "std_option__get_or"
      [ ("self", option_t); ("default_val", TyVar "T") ]
      (TyVar "T")
      (cvar "default_val" (TyVar "T"))
  in
  let fty =
    TyFunc { params = [ option_int; ty_int ]; return = ty_int; is_pure = true }
  in
  let caller_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "__ufcs_std$option__get_or" fty,
           [ cvar "opt" option_int; cint 0 ] ))
      ty_int
  in
  let caller = mk_func "caller" [ ("opt", option_int) ] ty_int caller_body in
  let result =
    Blorp.Core_mono.monomorphize_program [ mk_decl gf; mk_decl caller ]
  in
  let names =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "no get_or specialization emitted" false
    (List.mem "std_option__get_or__mono_Int" names);
  let caller_decl =
    List.find
      (fun d ->
        match d.cd_desc with CDFunc f -> f.cf_name = "caller" | _ -> false)
      result
  in
  match caller_decl.cd_desc with
  | CDFunc { cf_body = Some body; _ } -> (
      match body.desc with
      | CLet (_, { desc = CLet (_, { desc = CMatchArms _; _ }); _ }) -> ()
      | _ -> Alcotest.fail "expected get_or to fuse into strict let-bound match"
      )
  | _ -> Alcotest.fail "expected caller function"

let test_mono_fuses_option_get_or_else_call () =
  let option_t = TyNamed ("Option", [ TyVar "T" ]) in
  let option_int = TyNamed ("Option", [ ty_int ]) in
  let thunk_int = TyFunc { params = []; return = ty_int; is_pure = true } in
  let thunk_t = TyFunc { params = []; return = TyVar "T"; is_pure = true } in
  let gf =
    mk_func ~type_params:[ "T" ] ~module_path:(Some "std/option")
      "std_option__get_or_else"
      [ ("self", option_t); ("default_fn", thunk_t) ]
      (TyVar "T")
      (cvar "default_result" (TyVar "T"))
  in
  let fty =
    TyFunc
      { params = [ option_int; thunk_int ]; return = ty_int; is_pure = true }
  in
  let caller_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "__ufcs_std$option__get_or_else" fty,
           [ cvar "opt" option_int; cvar "default_fn" thunk_int ] ))
      ty_int
  in
  let caller =
    mk_func "caller"
      [ ("opt", option_int); ("default_fn", thunk_int) ]
      ty_int caller_body
  in
  let result =
    Blorp.Core_mono.monomorphize_program [ mk_decl gf; mk_decl caller ]
  in
  let names =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "no get_or_else specialization emitted" false
    (List.mem "std_option__get_or_else__mono_Int" names);
  let caller_decl =
    List.find
      (fun d ->
        match d.cd_desc with CDFunc f -> f.cf_name = "caller" | _ -> false)
      result
  in
  match caller_decl.cd_desc with
  | CDFunc { cf_body = Some body; _ } -> (
      match body.desc with
      | CLet (_, { desc = CLet (_, { desc = CMatchArms (_, arms); _ }); _ }) ->
          let none_calls_default =
            List.exists
              (fun (pat, arm) ->
                match (pat, arm.desc) with
                | PatConstructor ("None", []), CCall (_, _, []) -> true
                | _ -> false)
              arms
          in
          Alcotest.(check bool)
            "None arm calls default thunk lazily" true none_calls_default
      | _ ->
          Alcotest.fail "expected get_or_else to fuse into lazy let-bound match"
      )
  | _ -> Alcotest.fail "expected caller function"

(** Regression for the post-cutover bug where a module's own selective imports
    weren't consulted during mono, so a bare-name call in a std-lib module body
    (e.g. [zip(headers, row)] inside [std/csv.brp]) never triggered
    specialization. *)
let test_mono_module_scoped_import () =
  (* generic body stored under its prefixed name: std_list__zip *)
  let ty_ab = TyTuple [ TyVar "A"; TyVar "B" ] in
  let gf =
    mk_func ~type_params:[ "A"; "B" ] "std_list__zip"
      [
        ("list_a", TyNamed ("List", [ TyVar "A" ]));
        ("list_b", TyNamed ("List", [ TyVar "B" ]));
      ]
      (TyNamed ("List", [ ty_ab ]))
      (cvar "list_a" (TyNamed ("List", [ TyVar "A" ])))
  in
  (* caller uses bare name "zip" — imported via [list: zip] inside csv.brp *)
  let ty_list_str = TyNamed ("List", [ ty_string ]) in
  let fty =
    TyFunc
      {
        params = [ ty_list_str; ty_list_str ];
        return = TyNamed ("List", [ TyTuple [ ty_string; ty_string ] ]);
        is_pure = true;
      }
  in
  let caller_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "zip" fty,
           [ cvar "a" ty_list_str; cvar "b" ty_list_str ] ))
      (TyNamed ("List", [ TyTuple [ ty_string; ty_string ] ]))
  in
  let caller =
    mk_func ~module_path:(Some "std/csv") "std_csv__parse"
      [ ("a", ty_list_str); ("b", ty_list_str) ]
      (TyNamed ("List", [ TyTuple [ ty_string; ty_string ] ]))
      caller_body
  in
  let prog = [ mk_decl gf; mk_decl caller ] in
  (* Empty main-program import_aliases; per-module table maps zip → std/list. *)
  let module_imports : (string, (string, string * string) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 1
  in
  let csv_imports = Hashtbl.create 1 in
  Hashtbl.replace csv_imports "zip" ("std/list", "zip");
  Hashtbl.replace module_imports "std/csv" csv_imports;
  let result = Blorp.Core_mono.monomorphize_program ~module_imports prog in
  let names =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "has String/String specialization" true
    (List.mem "std_list__zip__mono_String_String" names)

let test_mono_module_global_import_concretizes_arg_metadata () =
  let ty_pair = TyTuple [ TyVar "A"; TyVar "B" ] in
  let gf =
    mk_func ~type_params:[ "A"; "B" ] ~module_path:(Some "std/list")
      "std_list__zip"
      [
        ("list_a", TyNamed ("List", [ TyVar "A" ]));
        ("list_b", TyNamed ("List", [ TyVar "B" ]));
      ]
      (TyNamed ("List", [ ty_pair ]))
      (mk (clist []) (TyNamed ("List", [ ty_pair ])))
  in
  let list_int = TyNamed ("List", [ ty_int ]) in
  let ret_ty = TyNamed ("List", [ TyTuple [ ty_int; ty_int ] ]) in
  let list_meta = TyNamed ("List", [ TyMeta 13 ]) in
  let fty =
    TyFunc { params = [ list_int; list_meta ]; return = ret_ty; is_pure = true }
  in
  let call =
    mk
      (CCall
         ( CKUnknown,
           cvar "zip" fty,
           [
             cvar "a" list_int; mk (clist [ cint 1; cint 2; cint 3 ]) list_meta;
           ] ))
      ret_ty
  in
  let global : core_var =
    {
      cv_name = Var.named "tests";
      cv_module = Some "tests/list_ops";
      cv_ty = ret_ty;
      cv_init = call;
      cv_is_mutable = false;
      cv_is_const = false;
      cv_def_id = 0;
    }
  in
  let module_imports : (string, (string, string * string) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 1
  in
  let imports = Hashtbl.create 1 in
  Hashtbl.replace imports "zip" ("std/list", "zip");
  Hashtbl.replace module_imports "tests/list_ops" imports;
  let result =
    Blorp.Core_mono.monomorphize_program ~module_imports
      [ mk_decl gf; { cd_desc = CDVar global; cd_loc = loc; cd_doc = None } ]
  in
  let global' =
    List.find_map
      (function
        | { cd_desc = CDVar v; _ } when v.cv_name.vname = "tests" -> Some v
        | _ -> None)
      result
  in
  match global' with
  | Some
      {
        cv_init =
          { desc = CCall (_, { desc = CVar callee; _ }, [ _; arg_b ]); _ };
        _;
      } ->
      Alcotest.(check string)
        "specialized module import" "std_list__zip__mono_Int_Int" callee.vname;
      Alcotest.(check string)
        "arg metadata concretized" "List[Int]"
        (Blorp.Types.type_to_string arg_b.ty)
  | _ -> Alcotest.fail "expected rewritten global initializer call"

(** Regression: [collect_subst] must expand type aliases on both sides.
    Otherwise a generic signature that names an alias type (e.g.
    [Decoder[T] = pure (Value) -> Result[T, _]]) won't match a call-site
    arg whose concrete type is already the aliased form, and no
    substitution is collected → the call is never specialized. *)
let test_mono_alias_expansion_in_subst () =
  (* Register an alias in a fresh local registry so [expand_alias] sees it.
     No globals touched — registry lifetime is scoped to this test. *)
  let ty_val = TyNamed ("Value", []) in
  let ty_derr = TyNamed ("DecodeError", []) in
  let alias_target =
    TyFunc
      {
        params = [ ty_val ];
        return = TyNamed ("Result", [ TyVar "T"; ty_derr ]);
        is_pure = true;
      }
  in
  let reg = empty_reg () in
  Hashtbl.replace reg.type_aliases "Decoder" ([ "T" ], alias_target);
  let subst =
    Blorp.Core_mono.collect_subst ~reg (tparams [ "T" ])
      (TyNamed ("Decoder", [ TyVar "T" ]))
      (TyFunc
         {
           params = [ ty_val ];
           return = TyNamed ("Result", [ ty_int; ty_derr ]);
           is_pure = true;
         })
      []
  in
  Alcotest.(check int) "one binding collected" 1 (List.length subst);
  Alcotest.(check string) "binds T" "T" (fst (List.hd subst));
  Alcotest.(check bool) "binds to Int" true (snd (List.hd subst) = st ty_int)

(* ============================================================================
   Phase 2.7 Cluster 2 — unrewritten-generic-call check
   ============================================================================ *)

(** Construct a program with an ambiguous generic call: [make[T]]
    returns [Option[T]], and [main] calls [make()] with no context to
    pin [T]. Mono's post-pass must raise [Core_error] — otherwise emit
    would skip [make]'s generic body and produce [undeclared function
    make] in the C output. *)
let test_mono_rejects_unrewritten_generic_call () =
  let make =
    mk_func ~type_params:[ "T" ] "make" []
      (TyNamed ("Option", [ TyVar "T" ]))
      (cvar "None" (TyNamed ("Option", [ TyVar "T" ])))
  in
  let fty =
    TyFunc
      {
        params = [];
        return = TyNamed ("Option", [ TyVar "T" ]);
        is_pure = true;
      }
  in
  (* Return type is Option[T] — T never pinned. *)
  let main_body =
    mk
      (CCall (CKUnknown, cvar "make" fty, []))
      (TyNamed ("Option", [ TyVar "T" ]))
  in
  let main_fn =
    mk_func "main" [] (TyNamed ("Option", [ TyVar "T" ])) main_body
  in
  let prog = [ mk_decl make; mk_decl main_fn ] in
  let fired =
    try
      let _ = Blorp.Core_mono.monomorphize_program prog in
      false
    with Blorp.Core_error.Core_error { msg; _ } ->
      let contains s n =
        let nl = String.length n and sl = String.length s in
        let rec find i =
          if i + nl > sl then false
          else if String.sub s i nl = n then true
          else find (i + 1)
        in
        nl <= sl && find 0
      in
      contains msg "Cannot infer type argument" && contains msg "make"
  in
  Alcotest.(check bool) "error fires on unrewritten generic call" true fired

(** Negative control: a concrete call to the same generic passes. *)
let test_mono_concrete_call_ok () =
  let make =
    mk_func ~type_params:[ "T" ] "make" []
      (TyNamed ("Option", [ TyVar "T" ]))
      (cvar "None" (TyNamed ("Option", [ TyVar "T" ])))
  in
  let fty =
    TyFunc
      { params = []; return = TyNamed ("Option", [ ty_int ]); is_pure = true }
  in
  let main_body =
    mk (CCall (CKUnknown, cvar "make" fty, [])) (TyNamed ("Option", [ ty_int ]))
  in
  let main_fn = mk_func "main" [] (TyNamed ("Option", [ ty_int ])) main_body in
  let prog = [ mk_decl make; mk_decl main_fn ] in
  (* Should not raise. *)
  let _ = Blorp.Core_mono.monomorphize_program prog in
  Alcotest.(check pass) "concrete call doesn't raise" () ()

(** A local first-class function binding must shadow a same-named generic
    top-level function. Mono should not specialize or rewrite this call by
    bare name; later closure conversion/resolution owns first-class calls. *)
let test_mono_local_function_binding_shadows_generic () =
  let generic_add =
    mk_func ~type_params:[ "T" ] "add"
      [ ("x", TyVar "T") ]
      (TyVar "T") (cvar "x" (TyVar "T"))
  in
  let local_fty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let local_lambda =
    mk
      (CLambda
         {
           lam_params = [ (Var.named "x", ty_int) ];
           lam_body = mk (CBin (Add, cvar "x" ty_int, cint 1)) ty_int;
           lam_return_ty = ty_int;
           lam_is_pure = true;
         })
      local_fty
  in
  let local_call =
    mk (CCall (CKUnknown, cvar "add" local_fty, [ cint 41 ])) ty_int
  in
  let main_body =
    mk
      (CLet
         ( {
             bind_var = Var.named "add";
             bind_mut = false;
             bind_ty = local_fty;
             bind_rhs = local_lambda;
           },
           local_call ))
      ty_int
  in
  let main_fn = mk_func "main" [] ty_int main_body in
  let result =
    Blorp.Core_mono.monomorphize_program
      [ mk_decl generic_add; mk_decl main_fn ]
  in
  let names =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "does not specialize shadowed generic" false
    (List.mem "add__mono_Int" names);
  let main_decl =
    List.find
      (fun d ->
        match d.cd_desc with CDFunc f -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc { cf_body = Some { desc = CLet (_, call); _ }; _ } -> (
      match call.desc with
      | CCall (_, { desc = CVar v; _ }, _) ->
          Alcotest.(check string) "callee remains local binding" "add" v.vname
      | _ -> Alcotest.fail "expected local call")
  | _ -> Alcotest.fail "expected main function with let body"

let test_mono_local_concrete_func_shadows_module_owned_generic () =
  let set_t = TyNamed ("Set", [ TyVar "T" ]) in
  let module_add =
    mk_func ~type_params:[ "T" ] ~module_path:(Some "std/set") "add"
      [ ("self", set_t); ("elem", TyVar "T") ]
      set_t (cvar "self" set_t)
  in
  let local_add =
    mk_func "add"
      [ ("a", ty_int); ("b", ty_int) ]
      ty_int
      (mk (CBin (Add, cvar "a" ty_int, cvar "b" ty_int)) ty_int)
  in
  let call_ty =
    TyFunc { params = [ ty_int; ty_int ]; return = ty_int; is_pure = true }
  in
  let main_body =
    mk (CCall (CKUnknown, cvar "add" call_ty, [ cint 3; cint 4 ])) ty_int
  in
  let main_fn = mk_func "main" [] ty_int main_body in
  let result =
    Blorp.Core_mono.monomorphize_program
      [ mk_decl module_add; mk_decl local_add; mk_decl main_fn ]
  in
  let names =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "does not specialize unrelated module generic" false
    (List.mem "add__mono_Int" names);
  let main_decl =
    List.find
      (fun d ->
        match d.cd_desc with CDFunc f -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar v; _ }, _); _ }; _ } ->
      Alcotest.(check string)
        "callee remains local concrete function" "add" v.vname
  | _ -> Alcotest.fail "expected concrete add call in main"

let test_mono_skips_qualified_ir_backed_length () =
  (* Qualified structural length calls lower as generic std function calls,
     but resolver turns them into IR intrinsics later. Mono must not reject
     or materialize the generic body when type args are irrelevant to the
     IR op. *)
  let dict_ty = TyNamed ("Dict", [ TyVar "K"; TyVar "V" ]) in
  let dict_len =
    mk_func ~type_params:[ "K"; "V" ] ~module_path:(Some "std/dict")
      "std_dict__length"
      [ ("self", dict_ty) ]
      ty_int (cint 0)
  in
  let d = cvar "d" dict_ty in
  let module_alias = cvar "D" (TyNamed ("Module", [])) in
  let callee =
    mk
      (CField (module_alias, "length"))
      (TyFunc { params = [ dict_ty ]; return = ty_int; is_pure = true })
  in
  let main_body = mk (CCall (CKUnknown, callee, [ d ])) ty_int in
  let main_fn = mk_func "main" [ ("d", dict_ty) ] ty_int main_body in
  let import_aliases = Hashtbl.create 1 in
  Hashtbl.replace import_aliases "D" ("std/dict", "");
  let result =
    Blorp.Core_mono.monomorphize_program ~import_aliases
      [ mk_decl dict_len; mk_decl main_fn ]
  in
  let names =
    List.filter_map
      (function { cd_desc = CDFunc f; _ } -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "does not materialize dict length mono" false
    (List.exists
       (fun name ->
         String.length name >= String.length "std_dict__length__mono"
         && String.sub name 0 (String.length "std_dict__length__mono")
            = "std_dict__length__mono")
       names)

let test_mono_skips_qualified_list_length_registry_entry () =
  let list_ty = TyNamed ("List", [ TyVar "T" ]) in
  let list_len =
    mk_func ~type_params:[ "T" ] ~module_path:(Some "std/list")
      "std_list__length"
      [ ("self", list_ty) ]
      ty_int (cint 0)
  in
  let xs = cvar "xs" list_ty in
  let module_alias = cvar "L" (TyNamed ("Module", [])) in
  let callee =
    mk
      (CField (module_alias, "length"))
      (TyFunc { params = [ list_ty ]; return = ty_int; is_pure = true })
  in
  let main_body = mk (CCall (CKUnknown, callee, [ xs ])) ty_int in
  let main_fn = mk_func "main" [ ("xs", list_ty) ] ty_int main_body in
  let import_aliases = Hashtbl.create 1 in
  Hashtbl.replace import_aliases "L" ("std/list", "");
  let result =
    Blorp.Core_mono.monomorphize_program ~import_aliases
      [ mk_decl list_len; mk_decl main_fn ]
  in
  let names =
    List.filter_map
      (function { cd_desc = CDFunc f; _ } -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "does not materialize list length mono" false
    (List.exists
       (fun name ->
         String.length name >= String.length "std_list__length__mono"
         && String.sub name 0 (String.length "std_list__length__mono")
            = "std_list__length__mono")
       names)

let test_mono_selective_import_beats_unqualified_builtin_generic () =
  let dict_ty = TyNamed ("Dict", [ TyVar "K"; TyVar "V" ]) in
  let set_ty = TyNamed ("Set", [ TyVar "T" ]) in
  let dict_contains =
    mk_func ~type_params:[ "K"; "V" ] ~module_path:(Some "std/dict")
      "std_dict__contains"
      [ ("self", dict_ty); ("key", TyVar "K") ]
      ty_bool
      (mk (CLit (LitBool true)) ty_bool)
  in
  let set_contains : core_func =
    {
      cf_name = "contains";
      cf_module = Some "std/set";
      cf_type_params = tparams [ "T" ];
      cf_params =
        [
          { cp_name = Var.named "self"; cp_ty = set_ty; cp_loc = loc };
          { cp_name = Var.named "elem"; cp_ty = TyVar "T"; cp_loc = loc };
        ];
      cf_return_ty = ty_bool;
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFBuiltin;
      cf_def_id = 0;
    }
  in
  let concrete_dict_ty = TyNamed ("Dict", [ ty_bool; ty_int ]) in
  let call_ty =
    TyFunc
      {
        params = [ concrete_dict_ty; ty_bool ];
        return = ty_bool;
        is_pure = true;
      }
  in
  let main_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "contains" call_ty,
           [ cvar "d" concrete_dict_ty; mk (CLit (LitBool false)) ty_bool ] ))
      ty_bool
  in
  let main_fn = mk_func "main" [ ("d", concrete_dict_ty) ] ty_bool main_body in
  let import_aliases = Hashtbl.create 1 in
  Hashtbl.replace import_aliases "contains" ("std/dict", "contains");
  let result =
    Blorp.Core_mono.monomorphize_program ~import_aliases
      [ mk_decl set_contains; mk_decl dict_contains; mk_decl main_fn ]
  in
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar v; _ }, _); _ }; _ } ->
      Alcotest.(check string)
        "selective import target" "std_dict__contains__mono_Bool_Int" v.vname
  | _ -> Alcotest.fail "expected rewritten main call"

let test_mono_module_owned_bare_builtin_generics_keep_distinct_identities () =
  let dict_ty = TyNamed ("Dict", [ TyVar "K"; TyVar "V" ]) in
  let set_ty = TyNamed ("Set", [ TyVar "T" ]) in
  let dict_contains : core_func =
    {
      cf_name = "contains";
      cf_module = Some "std/dict";
      cf_type_params = tparams [ "K"; "V" ];
      cf_params =
        [
          { cp_name = Var.named "self"; cp_ty = dict_ty; cp_loc = loc };
          { cp_name = Var.named "key"; cp_ty = TyVar "K"; cp_loc = loc };
        ];
      cf_return_ty = ty_bool;
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFBuiltin;
      cf_def_id = 0;
    }
  in
  let set_contains : core_func =
    {
      cf_name = "contains";
      cf_module = Some "std/set";
      cf_type_params = tparams [ "T" ];
      cf_params =
        [
          { cp_name = Var.named "self"; cp_ty = set_ty; cp_loc = loc };
          { cp_name = Var.named "elem"; cp_ty = TyVar "T"; cp_loc = loc };
        ];
      cf_return_ty = ty_bool;
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFBuiltin;
      cf_def_id = 0;
    }
  in
  let concrete_dict_ty = TyNamed ("Dict", [ ty_bool; ty_int ]) in
  let call_ty =
    TyFunc
      {
        params = [ concrete_dict_ty; ty_bool ];
        return = ty_bool;
        is_pure = true;
      }
  in
  let main_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "contains" call_ty,
           [ cvar "d" concrete_dict_ty; mk (CLit (LitBool false)) ty_bool ] ))
      ty_bool
  in
  let main_fn = mk_func "main" [ ("d", concrete_dict_ty) ] ty_bool main_body in
  let import_aliases = Hashtbl.create 1 in
  Hashtbl.replace import_aliases "contains" ("std/dict", "contains");
  let result =
    Blorp.Core_mono.monomorphize_program ~import_aliases
      [ mk_decl dict_contains; mk_decl set_contains; mk_decl main_fn ]
  in
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar v; _ }, _); _ }; _ } ->
      Alcotest.(check string)
        "selective import keeps dict identity"
        "std_dict__contains__mono_Bool_Int" v.vname
  | _ -> Alcotest.fail "expected rewritten main call"

let test_mono_concrete_selective_import_suppresses_unqualified_builtin_generic
    () =
  let set_ty = TyNamed ("Set", [ TyVar "T" ]) in
  let string_ty = TyNamed ("String", []) in
  let string_contains =
    mk_func ~module_path:(Some "std/string") "std_string__contains"
      [ ("self", string_ty); ("needle", string_ty) ]
      ty_bool
      (mk (CLit (LitBool true)) ty_bool)
  in
  let set_contains : core_func =
    {
      cf_name = "contains";
      cf_module = Some "std/set";
      cf_type_params = tparams [ "T" ];
      cf_params =
        [
          { cp_name = Var.named "self"; cp_ty = set_ty; cp_loc = loc };
          { cp_name = Var.named "elem"; cp_ty = TyVar "T"; cp_loc = loc };
        ];
      cf_return_ty = ty_bool;
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFBuiltin;
      cf_def_id = 0;
    }
  in
  let call_ty =
    TyFunc
      { params = [ string_ty; string_ty ]; return = ty_bool; is_pure = true }
  in
  let main_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "contains" call_ty,
           [ cvar "s" string_ty; cvar "needle" string_ty ] ))
      ty_bool
  in
  let main_fn =
    mk_func "main" [ ("s", string_ty); ("needle", string_ty) ] ty_bool main_body
  in
  let import_aliases = Hashtbl.create 1 in
  Hashtbl.replace import_aliases "contains" ("std/string", "contains");
  let result =
    Blorp.Core_mono.monomorphize_program ~import_aliases
      [ mk_decl set_contains; mk_decl string_contains; mk_decl main_fn ]
  in
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar v; _ }, _); _ }; _ } ->
      Alcotest.(check string)
        "leaves concrete import for resolve" "contains" v.vname
  | _ -> Alcotest.fail "expected main call"

let test_mono_runtime_backed_selective_import_waits_for_resolve () =
  let vector_generic_ty = TyArray (TyVar "T", [ TyVar "#N" ]) in
  let vector_concrete_ty = TyArray (ty_int, [ TyConstInt 3 ]) in
  let mapper_generic_ty =
    TyFunc { params = [ TyVar "T" ]; return = TyVar "U"; is_pure = true }
  in
  let mapper_concrete_ty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let vector_map : core_func =
    {
      cf_name = "map";
      cf_module = Some "std/vector";
      cf_type_params = tparams [ "T"; "U"; "#N" ];
      cf_params =
        [
          {
            cp_name = Var.named "self";
            cp_ty = vector_generic_ty;
            cp_loc = loc;
          };
          { cp_name = Var.named "f"; cp_ty = mapper_generic_ty; cp_loc = loc };
        ];
      cf_return_ty = TyArray (TyVar "U", [ TyVar "#N" ]);
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFBuiltin;
      cf_def_id = 0;
    }
  in
  let call_ty =
    TyFunc
      {
        params = [ vector_concrete_ty; mapper_concrete_ty ];
        return = vector_concrete_ty;
        is_pure = true;
      }
  in
  let main_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "map" call_ty,
           [ cvar "xs" vector_concrete_ty; cvar "f" mapper_concrete_ty ] ))
      vector_concrete_ty
  in
  let main_fn =
    mk_func "main"
      [ ("xs", vector_concrete_ty); ("f", mapper_concrete_ty) ]
      vector_concrete_ty main_body
  in
  let import_aliases = Hashtbl.create 1 in
  Hashtbl.replace import_aliases "map" ("std/vector", "map");
  let result =
    Blorp.Core_mono.monomorphize_program ~import_aliases
      [ mk_decl vector_map; mk_decl main_fn ]
  in
  let names =
    List.filter_map
      (function { cd_desc = CDFunc f; _ } -> Some f.cf_name | _ -> None)
      result
  in
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  Alcotest.(check bool)
    "does not materialize runtime-backed vector map mono" false
    (List.exists
       (fun name ->
         String.length name >= String.length "std_vector__map__mono"
         && String.sub name 0 (String.length "std_vector__map__mono")
            = "std_vector__map__mono")
       names);
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar v; _ }, _); _ }; _ } ->
      Alcotest.(check string)
        "leaves runtime-backed import for resolve" "map" v.vname
  | _ -> Alcotest.fail "expected main call"

let test_mono_selective_import_can_target_unqualified_builtin_generic () =
  let set_ty = TyNamed ("Set", [ TyVar "T" ]) in
  let set_contains : core_func =
    {
      cf_name = "contains";
      cf_module = Some "std/set";
      cf_type_params = tparams [ "T" ];
      cf_params =
        [
          { cp_name = Var.named "self"; cp_ty = set_ty; cp_loc = loc };
          { cp_name = Var.named "elem"; cp_ty = TyVar "T"; cp_loc = loc };
        ];
      cf_return_ty = ty_bool;
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFBuiltin;
      cf_def_id = 0;
    }
  in
  let concrete_set_ty = TyNamed ("Set", [ ty_bool ]) in
  let call_ty =
    TyFunc
      {
        params = [ concrete_set_ty; ty_bool ];
        return = ty_bool;
        is_pure = true;
      }
  in
  let main_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "contains" call_ty,
           [ cvar "s" concrete_set_ty; mk (CLit (LitBool true)) ty_bool ] ))
      ty_bool
  in
  let main_fn = mk_func "main" [ ("s", concrete_set_ty) ] ty_bool main_body in
  let import_aliases = Hashtbl.create 1 in
  Hashtbl.replace import_aliases "contains" ("std/set", "contains");
  let result =
    Blorp.Core_mono.monomorphize_program ~import_aliases
      [ mk_decl set_contains; mk_decl main_fn ]
  in
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar v; _ }, _); _ }; _ } ->
      Alcotest.(check string)
        "selective import builtin generic target" "std_set__contains__mono_Bool"
        v.vname
  | _ -> Alcotest.fail "expected rewritten main call"

let test_mono_prefixed_ufcs_builtin_generic_rewrites () =
  let set_ty = TyNamed ("Set", [ TyVar "T" ]) in
  let set_contains : core_func =
    {
      cf_name = "std_set__contains";
      cf_module = Some "std/set";
      cf_type_params = tparams [ "T" ];
      cf_params =
        [
          { cp_name = Var.named "self"; cp_ty = set_ty; cp_loc = loc };
          { cp_name = Var.named "elem"; cp_ty = TyVar "T"; cp_loc = loc };
        ];
      cf_return_ty = ty_bool;
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFBuiltin;
      cf_def_id = 0;
    }
  in
  let concrete_set_ty = TyNamed ("Set", [ ty_bool ]) in
  let call_ty =
    TyFunc
      {
        params = [ concrete_set_ty; ty_bool ];
        return = ty_bool;
        is_pure = true;
      }
  in
  let main_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "__ufcs_std$set__contains" call_ty,
           [ cvar "s" concrete_set_ty; mk (CLit (LitBool true)) ty_bool ] ))
      ty_bool
  in
  let main_fn = mk_func "main" [ ("s", concrete_set_ty) ] ty_bool main_body in
  let result =
    Blorp.Core_mono.monomorphize_program
      [ mk_decl set_contains; mk_decl main_fn ]
  in
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar v; _ }, _); _ }; _ } ->
      Alcotest.(check string)
        "prefixed UFCS builtin generic target" "std_set__contains__mono_Bool"
        v.vname
  | _ -> Alcotest.fail "expected rewritten main call"

let test_mono_ufcs_can_target_bare_module_builtin_generic () =
  let set_ty = TyNamed ("Set", [ TyVar "T" ]) in
  let set_contains : core_func =
    {
      cf_name = "contains";
      cf_module = Some "std/set";
      cf_type_params = tparams [ "T" ];
      cf_params =
        [
          { cp_name = Var.named "self"; cp_ty = set_ty; cp_loc = loc };
          { cp_name = Var.named "elem"; cp_ty = TyVar "T"; cp_loc = loc };
        ];
      cf_return_ty = ty_bool;
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFBuiltin;
      cf_def_id = 0;
    }
  in
  let concrete_set_ty = TyNamed ("Set", [ ty_bool ]) in
  let call_ty =
    TyFunc
      {
        params = [ concrete_set_ty; ty_bool ];
        return = ty_bool;
        is_pure = true;
      }
  in
  let main_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "__ufcs_std$set__contains" call_ty,
           [ cvar "s" concrete_set_ty; mk (CLit (LitBool true)) ty_bool ] ))
      ty_bool
  in
  let main_fn = mk_func "main" [ ("s", concrete_set_ty) ] ty_bool main_body in
  let result =
    Blorp.Core_mono.monomorphize_program
      [ mk_decl set_contains; mk_decl main_fn ]
  in
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar v; _ }, _); _ }; _ } ->
      Alcotest.(check string)
        "bare module UFCS builtin generic target" "std_set__contains__mono_Bool"
        v.vname
  | _ -> Alcotest.fail "expected rewritten main call"

let test_mono_ufcs_hof_builtin_generic_rewrites () =
  let import_symbol_ty = TyNamed ("ImportSymbol", []) in
  let key_param =
    Blorp.Generic_params.make_bound_type_param "K" [ "Orderable" ]
  in
  let list_t = TyNamed ("List", [ TyVar "T" ]) in
  let list_import_symbol = TyNamed ("List", [ import_symbol_ty ]) in
  let generic_key_fn =
    TyFunc { params = [ TyVar "T" ]; return = TyBoundVar key_param; is_pure = true }
  in
  let concrete_key_fn =
    TyFunc { params = [ import_symbol_ty ]; return = ty_string; is_pure = false }
  in
  let sort_by =
    mk_func ~type_params:[ "T" ] ~type_param_decls:[ key_param ]
      ~module_path:(Some "std/list")
      "std_list__sort_by"
      [ ("self", list_t); ("key_fn", generic_key_fn) ]
      list_t (cvar "self" list_t)
  in
  let call_ty =
    TyFunc
      {
        params = [ list_import_symbol; concrete_key_fn ];
        return = list_import_symbol;
        is_pure = true;
      }
  in
  let main_body =
    mk
      (CCall
         ( CKUnknown,
           cvar "__ufcs_std$list__sort_by" call_ty,
           [
             cvar "symbols" list_import_symbol;
             mk
               (CLambda
                  {
                    lam_params = [ (Var.named "item", import_symbol_ty) ];
                    lam_body = cvar "item_name" ty_string;
                    lam_return_ty = ty_string;
                    lam_is_pure = false;
                  })
               concrete_key_fn;
           ] ))
      list_import_symbol
  in
  let main_fn =
    mk_func "main" [ ("symbols", list_import_symbol) ] list_import_symbol
      main_body
  in
  let result =
    Blorp.Core_mono.monomorphize_program [ mk_decl sort_by; mk_decl main_fn ]
  in
  let names =
    List.filter_map
      (function { cd_desc = CDFunc f; _ } -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "emits concrete sort_by specialization" true
    (List.mem "std_list__sort_by__mono_String_ImportSymbol" names);
  let main_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "main" | _ -> false)
      result
  in
  match main_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar v; _ }, _); _ }; _ } ->
      Alcotest.(check string)
        "rewrites UFCS HOF generic call"
        "std_list__sort_by__mono_String_ImportSymbol" v.vname
  | _ -> Alcotest.fail "expected rewritten main call"

let test_mono_ufcs_user_wrapper_with_nested_generic_result_rewrites () =
  let list_t = TyNamed ("List", [ TyVar "T" ]) in
  let result_u =
    TyNamed
      ( "Result",
        [ TyVar "U"; TyNamed ("ConcurrencyError", []) ] )
  in
  let result_list_u = TyNamed ("List", [ result_u ]) in
  let callback_t_u =
    TyFunc
      { params = [ TyVar "T" ]; return = TyVar "U"; is_pure = false }
  in
  let wrapper =
    mk_func ~def_id:866 ~type_params:[ "T"; "U" ]
      ~module_path:(Some "std/list")
      "std_list__concurrent_with_timeout"
      [
        ("self", list_t);
        ("limit", ty_int);
        ("timeout", TyNamed ("std_units__Duration", []));
        ("f", callback_t_u);
      ]
      result_list_u (cvar "result" result_list_u)
  in
  let colliding_selected_id =
    mk_func ~def_id:503 ~type_params:[ "T"; "U" ]
      ~module_path:(Some "std/unrelated") "std_unrelated__map_with_timeout"
      [
        ("self", list_t);
        ("limit", ty_int);
        ("timeout", TyNamed ("std_units__Duration", []));
        ("f", callback_t_u);
      ]
      result_list_u (cvar "wrong_result" result_list_u)
  in
  let result_int =
    TyNamed
      ( "Result",
        [ ty_int; TyNamed ("ConcurrencyError", []) ] )
  in
  let concrete_result = TyNamed ("List", [ result_int ]) in
  let concrete_callback =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = false }
  in
  let call_ty =
    TyFunc
      {
        params =
          [
            TyNamed ("List", [ ty_int ]);
            ty_int;
            TyNamed ("std_units__Duration", []);
            concrete_callback;
          ];
        return = concrete_result;
        is_pure = false;
      }
  in
  let caller_body =
    mk
      (CCall
         ( CKSelectedDirect 503,
           cvar "__ufcs_std$list__concurrent_with_timeout" call_ty,
           [
             cvar "items" (TyNamed ("List", [ ty_int ]));
             cvar "limit" ty_int;
             cvar "timeout" (TyNamed ("std_units__Duration", []));
             cvar "f" concrete_callback;
           ] ))
      concrete_result
  in
  let caller =
    mk_func "caller"
      [
        ("items", TyNamed ("List", [ ty_int ]));
        ("limit", ty_int);
        ("timeout", TyNamed ("std_units__Duration", []));
        ("f", concrete_callback);
      ]
      concrete_result caller_body
  in
  let result =
    Blorp.Core_mono.monomorphize_program
      [ mk_decl wrapper; mk_decl colliding_selected_id; mk_decl caller ]
  in
  let names =
    List.filter_map
      (function { cd_desc = CDFunc f; _ } -> Some f.cf_name | _ -> None)
      result
  in
  Alcotest.(check bool)
    "emits concrete timeout wrapper specialization" true
    (List.mem
       "std_list__concurrent_with_timeout__mono_Int_Int"
       names)

let test_mono_bare_concrete_call_ignores_colliding_generic_id () =
  let list_t = TyNamed ("List", [ TyVar "T" ]) in
  let list_string = TyNamed ("List", [ ty_string ]) in
  let raw_environment = TyNamed ("RawProcessEnvironment", []) in
  let generic_sum =
    mk_func ~def_id:503 ~type_params:[ "T" ]
      ~module_path:(Some "std/list") "std_list__sum"
      [ ("self", list_t) ] (TyVar "T") (cvar "total" (TyVar "T"))
  in
  let concrete_environment =
    mk_func ~def_id:503 ~module_path:(Some "std/process")
      "raw_process_environment" [ ("changes", list_string) ] raw_environment
      (cvar "environment" raw_environment)
  in
  let call_ty =
    TyFunc
      {
        params = [ list_string ];
        return = raw_environment;
        is_pure = true;
      }
  in
  let caller_body =
    mk
      (CCall
         ( CKSelectedDirect 503,
           cvar "raw_process_environment" call_ty,
           [ cvar "changes" list_string ] ))
      raw_environment
  in
  let caller =
    mk_func "caller" [ ("changes", list_string) ] raw_environment caller_body
  in
  let result =
    Blorp.Core_mono.monomorphize_program
      [ mk_decl generic_sum; mk_decl concrete_environment; mk_decl caller ]
  in
  let caller_decl =
    List.find
      (function { cd_desc = CDFunc f; _ } -> f.cf_name = "caller" | _ -> false)
      result
  in
  match caller_decl.cd_desc with
  | CDFunc
      { cf_body = Some { desc = CCall (_, { desc = CVar callee; _ }, _); _ }; _ }
    ->
      Alcotest.(check string)
        "keeps the concrete callee" "raw_process_environment" callee.vname
  | _ -> Alcotest.fail "expected unchanged concrete call"

(* ============================================================================
   Test suite
   ============================================================================ *)

let suite =
  [
    ( "subst",
      [
        Alcotest.test_case "simple" `Quick test_collect_subst_simple;
        Alcotest.test_case "nested" `Quick test_collect_subst_nested;
        Alcotest.test_case "two_params" `Quick test_collect_subst_two_params;
        Alcotest.test_case "dedup_consistent_rejects_conflict" `Quick
          test_dedup_subst_consistent_rejects_conflict;
        Alcotest.test_case "dedup_consistent_refines_meta" `Quick
          test_dedup_subst_consistent_refines_meta;
        Alcotest.test_case "dedup_consistent_keeps_rigid_open" `Quick
          test_dedup_subst_consistent_does_not_refine_rigid;
        Alcotest.test_case "collect_subst_erases_range_refinements" `Quick
          test_collect_subst_erases_range_refinements;
        Alcotest.test_case "collect_subst_ignores_erased_dim_value_params"
          `Quick test_collect_subst_ignores_erased_dim_value_params;
        Alcotest.test_case "collect_subst_variadic_dim_packs" `Quick
          test_collect_subst_variadic_dim_packs;
        Alcotest.test_case "collect_subst_implicit_trailing_dim_pack" `Quick
          test_collect_subst_implicit_trailing_dim_pack;
        Alcotest.test_case "collect_subst_ignores_identity_bindings" `Quick
          test_collect_subst_ignores_identity_bindings;
        Alcotest.test_case "apply" `Quick test_apply_subst;
        Alcotest.test_case "apply_nested" `Quick test_apply_subst_nested;
        Alcotest.test_case "loop_binder" `Quick
          test_subst_core_types_updates_loop_binder;
        Alcotest.test_case "alias_expansion" `Quick
          test_mono_alias_expansion_in_subst;
      ] );
    ( "mangle",
      [
        Alcotest.test_case "simple" `Quick test_mangle_simple;
        Alcotest.test_case "two_params" `Quick test_mangle_two_params;
        Alcotest.test_case "container" `Quick test_mangle_container;
      ] );
    ( "mono",
      [
        Alcotest.test_case "simple" `Quick test_mono_simple;
        Alcotest.test_case "call_rewritten" `Quick test_mono_call_rewritten;
        Alcotest.test_case "types_specialized" `Quick
          test_mono_specialized_types;
        Alcotest.test_case "no_generics" `Quick test_mono_no_generics_unchanged;
        Alcotest.test_case "generic_record_data_layout" `Quick
          test_mono_materializes_generic_record_layout_without_generic_functions;
        Alcotest.test_case "generic_union_data_layout" `Quick
          test_mono_materializes_generic_union_layout_without_generic_functions;
        Alcotest.test_case "runtime_erased_bridge_union_data_layout" `Quick
          test_mono_keeps_runtime_erased_bridge_union_payload_storage;
        Alcotest.test_case "two_instances" `Quick test_mono_two_instantiations;
        Alcotest.test_case "repeated_type_param_consistent_call_ok" `Quick
          test_mono_repeated_type_param_consistent_call_ok;
        Alcotest.test_case "repeated_type_param_conflict_rejected" `Quick
          test_mono_rejects_conflicting_repeated_type_param_call;
        Alcotest.test_case "generic_trait_impl" `Quick
          test_mono_materializes_generic_trait_impl;
        Alcotest.test_case "e2e_pipeline" `Quick test_mono_e2e_pipeline;
        Alcotest.test_case "ufcs_mangled_callee" `Quick
          test_mono_ufcs_mangled_callee;
        Alcotest.test_case "bare call prefers selected direct kind generic"
          `Quick test_mono_bare_call_prefers_selected_direct_kind_generic;
        Alcotest.test_case "qualified call prefers selected direct kind generic"
          `Quick test_mono_qualified_call_prefers_selected_direct_kind_generic;
        Alcotest.test_case
          "selected registered generic builtin is specialized" `Quick
          test_mono_selected_registered_generic_builtin_is_specialized;
        Alcotest.test_case "selected direct requires matching signature" `Quick
          test_mono_selected_direct_requires_matching_signature;
        Alcotest.test_case "signature guard allows dimension params" `Quick
          test_mono_signature_guard_allows_dimension_params;
        Alcotest.test_case "signature guard allows wildcard dim pack" `Quick
          test_mono_signature_guard_allows_wildcard_dim_pack;
        Alcotest.test_case
          "prefixed runtime-backed call resolves without mono" `Quick
          test_mono_prefixed_runtime_backed_call_resolves_without_mono;
        Alcotest.test_case "option_get_or_call_fused" `Quick
          test_mono_fuses_option_get_or_call;
        Alcotest.test_case "option_get_or_else_call_fused" `Quick
          test_mono_fuses_option_get_or_else_call;
        Alcotest.test_case "module_scoped_import" `Quick
          test_mono_module_scoped_import;
        Alcotest.test_case "module_global_import_concretizes_arg_metadata"
          `Quick test_mono_module_global_import_concretizes_arg_metadata;
      ] );
    ( "cluster2_ambiguous_calls",
      [
        Alcotest.test_case "unrewritten generic rejected" `Quick
          test_mono_rejects_unrewritten_generic_call;
        Alcotest.test_case "concrete call still ok" `Quick
          test_mono_concrete_call_ok;
        Alcotest.test_case "local function binding shadows generic" `Quick
          test_mono_local_function_binding_shadows_generic;
        Alcotest.test_case
          "local concrete function shadows module-owned generic" `Quick
          test_mono_local_concrete_func_shadows_module_owned_generic;
        Alcotest.test_case "qualified IR-backed length skipped" `Quick
          test_mono_skips_qualified_ir_backed_length;
        Alcotest.test_case "qualified list length registry entry skipped" `Quick
          test_mono_skips_qualified_list_length_registry_entry;
        Alcotest.test_case "selective import beats unqualified builtin generic"
          `Quick test_mono_selective_import_beats_unqualified_builtin_generic;
        Alcotest.test_case
          "module-owned bare builtin generics keep distinct identities" `Quick
          test_mono_module_owned_bare_builtin_generics_keep_distinct_identities;
        Alcotest.test_case
          "concrete selective import suppresses unqualified builtin generic"
          `Quick
          test_mono_concrete_selective_import_suppresses_unqualified_builtin_generic;
        Alcotest.test_case "runtime-backed selective import waits for resolve"
          `Quick test_mono_runtime_backed_selective_import_waits_for_resolve;
        Alcotest.test_case
          "selective import can target unqualified builtin generic" `Quick
          test_mono_selective_import_can_target_unqualified_builtin_generic;
        Alcotest.test_case "prefixed UFCS builtin generic rewrites" `Quick
          test_mono_prefixed_ufcs_builtin_generic_rewrites;
        Alcotest.test_case "UFCS can target bare module builtin generic" `Quick
          test_mono_ufcs_can_target_bare_module_builtin_generic;
        Alcotest.test_case "UFCS HOF builtin generic rewrites" `Quick
          test_mono_ufcs_hof_builtin_generic_rewrites;
        Alcotest.test_case "UFCS user wrapper with nested generic result rewrites"
          `Quick test_mono_ufcs_user_wrapper_with_nested_generic_result_rewrites;
        Alcotest.test_case
          "bare concrete call ignores colliding generic id" `Quick
          test_mono_bare_concrete_call_ignores_colliding_generic_id;
      ] );
  ]
