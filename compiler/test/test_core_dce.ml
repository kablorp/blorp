(** Unit tests for Core dead-code elimination.

    The pass is intentionally conservative: it prunes only declaration classes
    with explicit reachability identities and complete dependency edges. *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_void = TyNamed ("Void", [])
let ty_bool = TyNamed ("Bool", [])
let ty_widget = TyNamed ("Widget", [])
let ty_box = TyNamed ("Box", [])
let ty_string = TyNamed ("String", [])
let ty_list_int = TyNamed ("List", [ ty_int ])
let ty_int128 = TyNamed ("Int128", [])
let ty_uint128 = TyNamed ("UInt128", [])
let ty_int_range = TyRange ty_int
let ty_t = TyVar "T"
let ty_option_int = TyNamed ("Option", [ ty_int ])
let ty_option_int128 = TyNamed ("Option", [ ty_int128 ])
let ty_option_uint128 = TyNamed ("Option", [ ty_uint128 ])
let ty_option_int_range = TyNamed ("Option", [ ty_int_range ])
let ty_result_int_int = TyNamed ("Result", [ ty_int; ty_int ])
let ty_result_int_string = TyNamed ("Result", [ ty_int; ty_string ])
let ty_list_widget = TyNamed ("List", [ ty_widget ])
let ty_set_widget = TyNamed ("Set", [ ty_widget ])
let ty_func_int = TyFunc { params = []; return = ty_int; is_pure = true }
let str_flags = { sf_triple = false; sf_raw = false }
let mk desc ty = { desc; ty; loc }
let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int
let cstr s = mk (CLit (LitString (s, str_flags))) ty_string
let cvoid = mk CVoid ty_void
let cvar name ty = mk (CVar (Var.named name)) ty

let call_user ?(def_id = Some 0) name =
  mk (CCall (CKUser (name, def_id), cvar name ty_func_int, [])) ty_int

let closure_ref def_id name =
  mk
    (CClosureCreate { cc_func = name; cc_def_id = def_id; cc_captures = [] })
    ty_func_int

let func ?(params = []) ?(type_params = []) ?(kind = CFUser) ?body id name =
  let cf_body = Option.value body ~default:(Some (cint id)) in
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = type_params;
    cf_params = params;
    cf_return_ty = ty_int;
    cf_body;
    cf_is_pure = true;
    cf_kind = kind;
    cf_def_id = id;
  }

let decl_func f = { cd_desc = CDFunc f; cd_loc = loc; cd_doc = None }

let decl_impl trait for_type methods =
  {
    cd_desc =
      CDImpl { ci_trait = trait; ci_for_type = for_type; ci_methods = methods };
    cd_loc = loc;
    cd_doc = None;
  }

let decl_record name fields =
  {
    cd_desc =
      CDRecord
        {
          record_name = name;
          record_type_params = [];
          record_fields =
            List.map
              (fun (field_name, field_type) ->
                { field_name; field_type; field_loc = loc })
              fields;
          record_is_value = false;
          record_is_builtin = false;
        };
    cd_loc = loc;
    cd_doc = None;
  }

let decl_value_record name fields =
  {
    cd_desc =
      CDRecord
        {
          record_name = name;
          record_type_params = [];
          record_fields =
            List.map
              (fun (field_name, field_type) ->
                { field_name; field_type; field_loc = loc })
              fields;
          record_is_value = true;
          record_is_builtin = false;
        };
    cd_loc = loc;
    cd_doc = None;
  }

let decl_generic_record name type_params fields =
  {
    cd_desc =
      CDRecord
        {
          record_name = name;
          record_type_params = type_params;
          record_fields =
            List.map
              (fun (field_name, field_type) ->
                { field_name; field_type; field_loc = loc })
              fields;
          record_is_value = false;
          record_is_builtin = false;
        };
    cd_loc = loc;
    cd_doc = None;
  }

let decl_type name variants =
  {
    cd_desc =
      CDType
        {
          type_name = name;
          type_params = [];
          type_variants = variants;
          type_is_enum = false;
          type_is_builtin = false;
          type_is_resource = false;
          type_resource_cleanup = None;
        };
    cd_loc = loc;
    cd_doc = None;
  }

let decl_enum name variants =
  {
    cd_desc =
      CDType
        {
          type_name = name;
          type_params = [];
          type_variants = variants;
          type_is_enum = true;
          type_is_builtin = false;
          type_is_resource = false;
          type_resource_cleanup = None;
        };
    cd_loc = loc;
    cd_doc = None;
  }

let variant ?def_id name fields =
  {
    variant_name = name;
    variant_fields = fields;
    variant_tag = 0;
    variant_loc = loc;
    variant_def_id = def_id;
  }

let decl_private_func f =
  { cd_desc = CDPrivate (decl_func f); cd_loc = loc; cd_doc = None }

let decl_global name init =
  {
    cd_desc =
      CDVar
        {
          cv_name = Var.named name;
          cv_module = None;
          cv_ty = ty_int;
          cv_init = init;
          cv_is_mutable = false;
          cv_is_const = false;
          cv_def_id = 10_000;
        };
    cd_loc = loc;
    cd_doc = None;
  }

let kept_function_names prog =
  let rec collect acc decl =
    match decl.cd_desc with
    | CDFunc f -> f.cf_name :: acc
    | CDImpl i ->
        List.fold_left
          (fun acc (f : core_func) ->
            Printf.sprintf "%s.%s" i.ci_trait f.cf_name :: acc)
          acc i.ci_methods
    | CDPrivate inner -> collect acc inner
    | _ -> acc
  in
  List.rev (List.fold_left collect [] prog)

let kept_type_decl_names prog =
  let rec collect acc decl =
    match decl.cd_desc with
    | CDRecord r -> ("record " ^ r.record_name) :: acc
    | CDType t -> ("type " ^ t.type_name) :: acc
    | CDPrivate inner -> collect acc inner
    | _ -> acc
  in
  List.rev (List.fold_left collect [] prog)

let kept_impl_names prog =
  let rec collect acc decl =
    match decl.cd_desc with
    | CDImpl i -> i.ci_trait :: acc
    | CDPrivate inner -> collect acc inner
    | _ -> acc
  in
  List.rev (List.fold_left collect [] prog)

let prune prog =
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Core_flatten.register_types reg prog;
  Blorp.Core_dce.prune_unreachable_declarations ~reg prog

let analyze prog =
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Core_flatten.register_types reg prog;
  Blorp.Core_dce.analyze_reachability ~reg prog

let has_root graph decl reason =
  match Hashtbl.find_opt graph.Blorp.Core_dce.roots decl with
  | Some reasons -> List.exists (( = ) reason) reasons
  | None -> false

let has_edge graph source target reason =
  match Hashtbl.find_opt graph.Blorp.Core_dce.edges source with
  | Some edges ->
      List.exists
        (fun (edge : Blorp.Core_dce.dependency_edge) ->
          edge.de_target = target && edge.de_reason = reason)
        edges
  | None -> false

let test_prunes_unreachable_concrete_function () =
  let main = func 1 "main" ~body:(Some (call_user ~def_id:(Some 2) "helper")) in
  let helper = func 2 "helper" in
  let dead = func 3 "dead" in
  let pruned = prune [ decl_func main; decl_func helper; decl_func dead ] in
  Alcotest.(check (list string))
    "dead concrete function pruned" [ "main"; "helper" ]
    (kept_function_names pruned)

let test_keeps_private_reachable_function () =
  let main = func 1 "main" ~body:(Some (call_user ~def_id:(Some 2) "helper")) in
  let helper = func 2 "helper" in
  let dead = func 3 "dead" in
  let pruned =
    prune [ decl_func main; decl_private_func helper; decl_private_func dead ]
  in
  Alcotest.(check (list string))
    "reachable private function kept" [ "main"; "helper" ]
    (kept_function_names pruned)

let test_keeps_function_referenced_by_closure_create () =
  let body = mk (CSeq (closure_ref 2 "adapter", cint 0)) ty_int in
  let main = func 1 "main" ~body:(Some body) in
  let adapter = func 2 "adapter" in
  let dead = func 3 "dead" in
  let pruned = prune [ decl_func main; decl_func adapter; decl_func dead ] in
  Alcotest.(check (list string))
    "closure target kept" [ "main"; "adapter" ]
    (kept_function_names pruned)

let test_global_initializer_roots_reachable_functions () =
  let main = func 1 "main" in
  let helper = func 2 "helper" in
  let dead = func 3 "dead" in
  let global = decl_global "x" (call_user ~def_id:(Some 2) "helper") in
  let pruned =
    prune [ global; decl_func main; decl_func helper; decl_func dead ]
  in
  Alcotest.(check (list string))
    "global init helper kept" [ "main"; "helper" ]
    (kept_function_names pruned)

let test_unresolved_user_call_identity_fails_closed () =
  let main = func 1 "main" ~body:(Some (call_user ~def_id:None "helper")) in
  let helper = func 2 "helper" in
  let dead = func 3 "dead" in
  let pruned = prune [ decl_func main; decl_func helper; decl_func dead ] in
  Alcotest.(check (list string))
    "unresolved user call keeps all concrete functions"
    [ "main"; "helper"; "dead" ]
    (kept_function_names pruned)

let test_fail_closed_retains_generic_templates () =
  let main = func 1 "main" ~body:(Some (call_user ~def_id:None "helper")) in
  let generic =
    func 2 "identity"
      ~type_params:[ make_type_param "T" [] ]
      ~params:[ { cp_name = Var.named "value"; cp_ty = ty_t; cp_loc = loc } ]
      ~body:(Some (cvar "value" ty_t))
  in
  let pruned = prune [ decl_func main; decl_func generic ] in
  Alcotest.(check (list string))
    "fail-closed analysis keeps generic templates" [ "main"; "identity" ]
    (kept_function_names pruned)

let test_keeps_non_concrete_functions () =
  let main = func 1 "main" in
  let builtin = func 2 "builtin_helper" ~kind:CFBuiltin ~body:None in
  let foreign =
    func 3 "foreign_helper"
      ~kind:
        (CFForeign
           {
             c_name = "foreign_helper";
             includes = [ "foreign.h" ];
             link_flags = [];
             arg_passing = ForeignBorrowArgs;
           })
      ~body:None
  in
  let pruned = prune [ decl_func main; decl_func builtin; decl_func foreign ] in
  Alcotest.(check (list string))
    "non-concrete functions kept"
    [ "main"; "builtin_helper"; "foreign_helper" ]
    (kept_function_names pruned)

let test_prunes_non_runtime_generic_function_templates () =
  let main = func 1 "main" in
  let generic =
    func 2 "identity"
      ~type_params:[ make_type_param "T" [] ]
      ~params:[ { cp_name = Var.named "value"; cp_ty = ty_t; cp_loc = loc } ]
      ~body:(Some (cvar "value" ty_t))
  in
  let pruned = prune [ decl_func main; decl_func generic ] in
  Alcotest.(check (list string))
    "generic function template pruned before ownership passes" [ "main" ]
    (kept_function_names pruned)

let test_prunes_unreachable_impl_methods () =
  let main =
    func 1 "main"
      ~body:(Some (call_user ~def_id:(Some 2) "Describable_describe_Widget"))
  in
  let describe = func 2 "describe" ~body:(Some (cstr "widget")) in
  let unused = func 3 "unused" ~body:(Some (cstr "unused")) in
  let pruned =
    prune
      [ decl_func main; decl_impl "Describable" ty_widget [ describe; unused ] ]
  in
  Alcotest.(check (list string))
    "unused impl method pruned"
    [ "main"; "Describable.describe" ]
    (kept_function_names pruned)

let test_prunes_empty_concrete_impl_declarations () =
  let main = func 1 "main" in
  let unused = func 2 "unused" ~body:(Some (cstr "unused")) in
  let pruned =
    prune [ decl_func main; decl_impl "Describable" ty_widget [ unused ] ]
  in
  Alcotest.(check (list string))
    "empty concrete impl declaration pruned" [] (kept_impl_names pruned)

let test_prunes_non_runtime_generic_impl_templates () =
  let main = func 1 "main" in
  let describe =
    func 2 "describe"
      ~type_params:[ make_type_param "T" [] ]
      ~params:
        [
          {
            cp_name = Var.named "value";
            cp_ty = TyNamed ("Box", [ ty_t ]);
            cp_loc = loc;
          };
        ]
      ~body:(Some (cstr "box"))
  in
  let pruned =
    prune
      [
        decl_func main;
        decl_impl "Describable" (TyNamed ("Box", [ ty_t ])) [ describe ];
      ]
  in
  Alcotest.(check (list string))
    "generic impl template pruned before ownership passes" []
    (kept_impl_names pruned)

let test_custom_dict_constructor_roots_hash_callbacks () =
  let dict_ty = TyNamed ("Dict", [ ty_widget; ty_int ]) in
  let main =
    func 1 "main"
      ~body:
        (Some
           (mk
              (CCall
                 ( CKBuiltin "blorp_dict_new_custom",
                   cvar "blorp_dict_new_custom"
                     (TyFunc { params = []; return = dict_ty; is_pure = true }),
                   [] ))
              dict_ty))
  in
  let hash = func 2 "hash" in
  let equals =
    func 3 "equals" ~body:(Some (mk (CLit (LitBool true)) ty_bool))
  in
  let unused =
    func 4 "not_equals" ~body:(Some (mk (CLit (LitBool false)) ty_bool))
  in
  let pruned =
    prune
      [
        decl_func main;
        decl_impl "Hashable" ty_widget [ hash ];
        decl_impl "Equatable" ty_widget [ equals; unused ];
      ]
  in
  Alcotest.(check (list string))
    "custom dict callbacks kept"
    [ "main"; "Hashable.hash"; "Equatable.equals" ]
    (kept_function_names pruned)

let test_custom_set_constructor_roots_hash_callbacks () =
  let main =
    func 1 "main"
      ~body:
        (Some
           (mk
              (CSetAlloc { sa_constructor = SetCustom ty_widget })
              ty_set_widget))
  in
  let hash = func 2 "hash" in
  let equals =
    func 3 "equals" ~body:(Some (mk (CLit (LitBool true)) ty_bool))
  in
  let unused =
    func 4 "not_equals" ~body:(Some (mk (CLit (LitBool false)) ty_bool))
  in
  let pruned =
    prune
      [
        decl_func main;
        decl_impl "Hashable" ty_widget [ hash ];
        decl_impl "Equatable" ty_widget [ equals; unused ];
      ]
  in
  Alcotest.(check (list string))
    "custom set callbacks kept"
    [ "main"; "Hashable.hash"; "Equatable.equals" ]
    (kept_function_names pruned)

let test_list_to_string_roots_stringable_callback () =
  let main =
    func 1 "main"
      ~body:
        (Some
           (mk
              (CCall
                 ( CKBuiltin "blorp_list_to_string_cb",
                   cvar "blorp_list_to_string_cb"
                     (TyFunc
                        {
                          params = [ ty_list_widget ];
                          return = ty_string;
                          is_pure = true;
                        }),
                   [ cvar "widgets" ty_list_widget ] ))
              ty_string))
  in
  let to_string = func 2 "to_string" ~body:(Some (cstr "widget")) in
  let unused = func 3 "unused" ~body:(Some (cstr "unused")) in
  let pruned =
    prune
      [ decl_func main; decl_impl "Stringable" ty_widget [ to_string; unused ] ]
  in
  Alcotest.(check (list string))
    "list to_string callback kept"
    [ "main"; "Stringable.to_string" ]
    (kept_function_names pruned)

let test_prunes_unreachable_monomorphic_type_declarations () =
  let used_union_ty = TyNamed ("UsedUnion", []) in
  let main =
    {
      (func 1 "main") with
      cf_params =
        [
          { cp_name = Var.named "widget"; cp_ty = ty_widget; cp_loc = loc };
          { cp_name = Var.named "union"; cp_ty = used_union_ty; cp_loc = loc };
        ];
    }
  in
  let pruned =
    prune
      [
        decl_record "Widget" [ ("label", ty_string) ];
        decl_record "UnusedRecord" [ ("label", ty_string) ];
        decl_type "UsedUnion" [ variant "Wrapped" [ ty_widget ] ];
        decl_type "UnusedUnion" [ variant "Dead" [ ty_int ] ];
        decl_func main;
      ]
  in
  Alcotest.(check (list string))
    "only reachable monomorphic type declarations kept"
    [ "record Widget"; "type UsedUnion" ]
    (kept_type_decl_names pruned)

let test_retains_generic_type_templates () =
  let main = func 1 "main" in
  let pruned =
    prune
      [
        decl_generic_record "GenericBox"
          [ make_type_param "T" [] ]
          [ ("value", ty_t) ];
        decl_func main;
      ]
  in
  Alcotest.(check (list string))
    "generic record template retained until monomorphic identity is modeled"
    [ "record GenericBox" ]
    (kept_type_decl_names pruned)

let test_retains_global_abi_type_layout_anchors () =
  let main = func 1 "main" in
  let pruned =
    prune
      [
        decl_value_record "Range" [ ("start", ty_int); ("end", ty_int) ];
        decl_func main;
      ]
  in
  Alcotest.(check (list string))
    "global ABI type declarations retained as layout anchors" [ "record Range" ]
    (kept_type_decl_names pruned)

let test_dependency_graph_records_roots_and_edges () =
  let main = func 1 "main" ~body:(Some (call_user ~def_id:(Some 2) "helper")) in
  let helper =
    func 2 "helper"
      ~body:(Some (mk (CSeq (closure_ref 3 "adapter", cint 0)) ty_int))
  in
  let adapter = func 3 "adapter" in
  let analysis =
    analyze [ decl_func main; decl_func helper; decl_func adapter ]
  in
  let graph = analysis.Blorp.Core_dce.dependency_graph in
  Alcotest.(check bool)
    "main root recorded" true
    (has_root graph (Blorp.Core_dce.FunctionBody 1) Blorp.Core_dce.RootMain);
  Alcotest.(check bool)
    "direct call edge recorded" true
    (has_edge graph (Blorp.Core_dce.FunctionBody 1)
       (Blorp.Core_dce.FunctionBody 2) Blorp.Core_dce.DirectCall);
  Alcotest.(check bool)
    "closure edge recorded" true
    (has_edge graph (Blorp.Core_dce.FunctionBody 2)
       (Blorp.Core_dce.FunctionBody 3) Blorp.Core_dce.ClosureCreate)

let test_dependency_graph_records_type_edges () =
  let main =
    {
      (func 1 "main") with
      cf_params =
        [ { cp_name = Var.named "box"; cp_ty = ty_box; cp_loc = loc } ];
      cf_return_ty = ty_box;
      cf_body = Some (cvar "box" ty_box);
    }
  in
  let analysis =
    analyze
      [
        decl_record "Widget" [ ("label", ty_string) ];
        decl_type "Box" [ variant "Wrapped" [ ty_widget ] ];
        decl_func main;
      ]
  in
  let graph = analysis.Blorp.Core_dce.dependency_graph in
  Alcotest.(check bool)
    "function signature type edge recorded" true
    (has_edge graph (Blorp.Core_dce.FunctionBody 1)
       (Blorp.Core_dce.TypeDecl "Box")
       (Blorp.Core_dce.TypeDependency Blorp.Core_dce.FunctionSignatureType));
  Alcotest.(check bool)
    "union variant field type edge recorded" true
    (has_edge graph (Blorp.Core_dce.TypeDecl "Box")
       (Blorp.Core_dce.RecordDecl "Widget")
       (Blorp.Core_dce.TypeDependency
          (Blorp.Core_dce.UnionVariantFieldType { variant_name = "Wrapped" })))

let test_dependency_graph_records_runtime_artifact_edges () =
  let main =
    {
      (func 1 "main") with
      cf_params =
        [ { cp_name = Var.named "box"; cp_ty = ty_box; cp_loc = loc } ];
      cf_return_ty = ty_box;
      cf_body = Some (cvar "box" ty_box);
    }
  in
  let analysis =
    analyze
      [
        decl_record "Widget" [ ("label", ty_string) ];
        decl_type "Box" [ variant ~def_id:42 "Wrapped" [ ty_widget ] ];
        decl_func main;
      ]
  in
  let graph = analysis.Blorp.Core_dce.dependency_graph in
  let widget_constructor =
    Blorp.Core_dce.ConstructorDecl
      (Blorp.Core_dce.RecordConstructor
         { type_name = "Widget"; c_name = "Widget_make" })
  in
  let widget_destructor =
    Blorp.Core_dce.DestructorDecl
      (Blorp.Core_dce.RecordDestructor
         { type_name = "Widget"; c_name = "Widget_destroy" })
  in
  let widget_type_tag =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.HeapRecordRuntimeTypeTag { type_name = "Widget" })
  in
  let box_constructor =
    Blorp.Core_dce.ConstructorDecl
      (Blorp.Core_dce.UnionConstructor
         {
           parent_type = "Box";
           variant_name = "Wrapped";
           c_name = "__def_42_Wrapped";
         })
  in
  let box_destructor =
    Blorp.Core_dce.DestructorDecl
      (Blorp.Core_dce.UnionDestructor
         { type_name = "Box"; c_name = "Box_destroy" })
  in
  let box_type_tag =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.UnionRuntimeTypeTag { type_name = "Box" })
  in
  Alcotest.(check bool)
    "record constructor artifact edge recorded" true
    (has_edge graph (Blorp.Core_dce.RecordDecl "Widget") widget_constructor
       (Blorp.Core_dce.ConstructorDependency Blorp.Core_dce.RecordTypeLayout));
  Alcotest.(check bool)
    "record destructor artifact edge recorded" true
    (has_edge graph (Blorp.Core_dce.RecordDecl "Widget") widget_destructor
       (Blorp.Core_dce.DestructorDependency Blorp.Core_dce.HeapRecordTypeLayout));
  Alcotest.(check bool)
    "record runtime type tag edge recorded" true
    (has_edge graph (Blorp.Core_dce.RecordDecl "Widget") widget_type_tag
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.HeapRecordRuntimeTypeTagLayout));
  Alcotest.(check bool)
    "union constructor artifact edge recorded" true
    (has_edge graph (Blorp.Core_dce.TypeDecl "Box") box_constructor
       (Blorp.Core_dce.ConstructorDependency
          (Blorp.Core_dce.UnionVariantLayout { variant_name = "Wrapped" })));
  Alcotest.(check bool)
    "union destructor artifact edge recorded" true
    (has_edge graph (Blorp.Core_dce.TypeDecl "Box") box_destructor
       (Blorp.Core_dce.DestructorDependency Blorp.Core_dce.UnionTypeLayout));
  Alcotest.(check bool)
    "union runtime type tag edge recorded" true
    (has_edge graph (Blorp.Core_dce.TypeDecl "Box") box_type_tag
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.UnionRuntimeTypeTagLayout))

let test_dependency_graph_skips_generic_runtime_artifacts () =
  let generic_box_ty = TyNamed ("GenericBox", [ ty_widget ]) in
  let main =
    {
      (func 1 "main") with
      cf_params =
        [ { cp_name = Var.named "box"; cp_ty = generic_box_ty; cp_loc = loc } ];
      cf_return_ty = generic_box_ty;
      cf_body = Some (cvar "box" generic_box_ty);
    }
  in
  let analysis =
    analyze
      [
        decl_record "Widget" [ ("label", ty_string) ];
        decl_generic_record "GenericBox"
          [ make_type_param "T" [] ]
          [ ("value", TyVar "T") ];
        decl_func main;
      ]
  in
  let graph = analysis.Blorp.Core_dce.dependency_graph in
  let generic_constructor =
    Blorp.Core_dce.ConstructorDecl
      (Blorp.Core_dce.RecordConstructor
         { type_name = "GenericBox"; c_name = "GenericBox_make" })
  in
  Alcotest.(check bool)
    "generic record constructor artifact not modeled as concrete edge" false
    (has_edge graph (Blorp.Core_dce.RecordDecl "GenericBox") generic_constructor
       (Blorp.Core_dce.ConstructorDependency Blorp.Core_dce.RecordTypeLayout))

let test_dependency_graph_records_record_erased_field_release_mask_artifacts ()
    =
  let generic_box_ty = TyNamed ("GenericBox", [ ty_string ]) in
  let main =
    {
      (func 1 "main") with
      cf_params =
        [ { cp_name = Var.named "box"; cp_ty = generic_box_ty; cp_loc = loc } ];
      cf_return_ty = ty_int;
    }
  in
  let analysis =
    analyze
      [
        decl_generic_record "GenericBox"
          [ make_type_param "T" [] ]
          [ ("id", ty_int); ("value", ty_t) ];
        decl_func main;
      ]
  in
  let graph = analysis.Blorp.Core_dce.dependency_graph in
  let release_mask =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.RecordErasedFieldReleaseMask
         {
           type_name = "GenericBox";
           erased_fields =
             [
               {
                 Blorp.Core_dce.erased_field_name = "value";
                 erased_field_index = 1;
               };
             ];
         })
  in
  Alcotest.(check bool)
    "generic record erased-field release mask edge recorded" true
    (has_edge graph (Blorp.Core_dce.RecordDecl "GenericBox") release_mask
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.RecordErasedFieldReleaseMaskLayout))

let test_dependency_graph_records_runtime_builtin_lifecycle_artifacts () =
  let main =
    {
      (func 1 "main") with
      cf_params =
        [
          { cp_name = Var.named "text"; cp_ty = ty_string; cp_loc = loc };
          { cp_name = Var.named "items"; cp_ty = ty_list_int; cp_loc = loc };
        ];
      cf_return_ty = ty_int;
    }
  in
  let analysis = analyze [ decl_func main ] in
  let graph = analysis.Blorp.Core_dce.dependency_graph in
  let string_lifecycle =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.RuntimeManagedBuiltinLifecycle
         {
           type_name = "String";
           c_type = "blorp_String*";
           release_path = Blorp.Core_dce.RuntimeBuiltinArcReleaseOnly;
         })
  in
  let list_lifecycle =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.RuntimeManagedBuiltinLifecycle
         {
           type_name = "List";
           c_type = "blorp_List*";
           release_path =
             Blorp.Core_dce.RuntimeBuiltinDestructor "blorp_list_destroy";
         })
  in
  Alcotest.(check bool)
    "runtime release-only builtin lifecycle edge recorded" true
    (has_edge graph (Blorp.Core_dce.FunctionBody 1) string_lifecycle
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.RuntimeManagedBuiltinLifecycleLayout));
  Alcotest.(check bool)
    "runtime destructor builtin lifecycle edge recorded" true
    (has_edge graph (Blorp.Core_dce.FunctionBody 1) list_lifecycle
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.RuntimeManagedBuiltinLifecycleLayout))

let test_dependency_graph_records_tag_and_singleton_artifacts () =
  let main =
    {
      (func 1 "main") with
      cf_params =
        [
          {
            cp_name = Var.named "color";
            cp_ty = TyNamed ("Color", []);
            cp_loc = loc;
          };
          {
            cp_name = Var.named "status";
            cp_ty = TyNamed ("Status", []);
            cp_loc = loc;
          };
        ];
      cf_return_ty = ty_int;
    }
  in
  let analysis =
    analyze
      [
        decl_enum "Color"
          [
            { (variant ~def_id:51 "Red" []) with variant_tag = 0 };
            { (variant ~def_id:52 "Blue" []) with variant_tag = 1 };
          ];
        decl_type "Status"
          [
            { (variant ~def_id:61 "Idle" []) with variant_tag = 0 };
            { (variant ~def_id:62 "Busy" [ ty_string ]) with variant_tag = 1 };
          ];
        decl_func main;
      ]
  in
  let graph = analysis.Blorp.Core_dce.dependency_graph in
  let color_red =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.EnumVariantMacro
         { type_name = "Color"; variant_name = "Red"; c_name = "__def_51_Red" })
  in
  let color_to_string =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.EnumStringifier
         { type_name = "Color"; c_name = "__blorp_enum_to_string_Color" })
  in
  let color_vector_to_string =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.EnumVectorStringifier
         { type_name = "Color"; c_name = "blorp_vector_to_string_Color" })
  in
  let status_idle_tag =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.UnionTagMacro
         {
           type_name = "Status";
           variant_name = "Idle";
           c_name = "TAG_Status_Idle";
         })
  in
  let status_release_mask =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.UnionReleaseMask { type_name = "Status" })
  in
  let status_idle_singleton =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.UnionSingleton
         {
           parent_type = "Status";
           variant_name = "Idle";
           constructor_c_name = "__def_61_Idle";
           instance_c_name = "__instance___def_61_Idle";
           init_c_name = "__init___def_61_Idle";
         })
  in
  Alcotest.(check bool)
    "enum variant macro edge recorded" true
    (has_edge graph (Blorp.Core_dce.TypeDecl "Color") color_red
       (Blorp.Core_dce.GeneratedArtifactDependency
          (Blorp.Core_dce.EnumVariantTagLayout { variant_name = "Red" })));
  Alcotest.(check bool)
    "enum stringifier edge recorded" true
    (has_edge graph (Blorp.Core_dce.TypeDecl "Color") color_to_string
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.EnumStringification));
  Alcotest.(check bool)
    "enum vector stringifier edge recorded" true
    (has_edge graph (Blorp.Core_dce.TypeDecl "Color") color_vector_to_string
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.EnumVectorStringification));
  Alcotest.(check bool)
    "union tag macro edge recorded" true
    (has_edge graph (Blorp.Core_dce.TypeDecl "Status") status_idle_tag
       (Blorp.Core_dce.GeneratedArtifactDependency
          (Blorp.Core_dce.UnionVariantTagLayout { variant_name = "Idle" })));
  Alcotest.(check bool)
    "union release mask edge recorded" true
    (has_edge graph (Blorp.Core_dce.TypeDecl "Status") status_release_mask
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.UnionReleaseMaskLayout));
  Alcotest.(check bool)
    "nullary union singleton edge recorded" true
    (has_edge graph (Blorp.Core_dce.TypeDecl "Status") status_idle_singleton
       (Blorp.Core_dce.GeneratedArtifactDependency
          (Blorp.Core_dce.UnionNullaryVariantSingleton { variant_name = "Idle" })))

let test_dependency_graph_records_source_stack_option_layout_artifacts () =
  let score_ty = TyNamed ("Score", []) in
  let color_ty = TyNamed ("Color", []) in
  let main =
    {
      (func 1 "main") with
      cf_params =
        [
          { cp_name = Var.named "score"; cp_ty = score_ty; cp_loc = loc };
          { cp_name = Var.named "color"; cp_ty = color_ty; cp_loc = loc };
        ];
      cf_return_ty = ty_int;
    }
  in
  let analysis =
    analyze
      [
        decl_value_record "Score" [ ("value", ty_int) ];
        decl_enum "Color"
          [
            { (variant ~def_id:51 "Red" []) with variant_tag = 0 };
            { (variant ~def_id:52 "Blue" []) with variant_tag = 1 };
          ];
        decl_func main;
      ]
  in
  let graph = analysis.Blorp.Core_dce.dependency_graph in
  let score_stack_option =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.StackOptionSpecialization
         {
           payload_type = "Score";
           option_c_type = "blorp_StackOption_Score";
           payload_c_type = "Score";
         })
  in
  let color_stack_option =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.StackOptionSpecialization
         {
           payload_type = "Color";
           option_c_type = "blorp_StackOption_Color";
           payload_c_type = "long";
         })
  in
  Alcotest.(check bool)
    "value record stack option typedef edge recorded" true
    (has_edge graph (Blorp.Core_dce.RecordDecl "Score") score_stack_option
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.SourceGeneratedStackOptionLayout));
  Alcotest.(check bool)
    "enum stack option typedef edge recorded" true
    (has_edge graph (Blorp.Core_dce.TypeDecl "Color") color_stack_option
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.SourceGeneratedStackOptionLayout))

let test_dependency_graph_records_runtime_stack_option_layout_artifacts () =
  let main =
    {
      (func 1 "main") with
      cf_return_ty = ty_option_int;
      cf_body = Some (cvar "maybe" ty_option_int);
    }
  in
  let analysis = analyze [ decl_func main ] in
  let graph = analysis.Blorp.Core_dce.dependency_graph in
  let int_stack_option =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.StackOptionSpecialization
         {
           payload_type = "Int";
           option_c_type = "blorp_StackOption_Int";
           payload_c_type = "long";
         })
  in
  Alcotest.(check bool)
    "runtime stack option typedef edge recorded" true
    (has_edge graph (Blorp.Core_dce.FunctionBody 1) int_stack_option
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.RuntimeOwnedStackOptionLayout))

let test_dependency_graph_records_backend_stack_option_layout_artifacts () =
  let main =
    {
      (func 1 "main") with
      cf_params =
        [
          {
            cp_name = Var.named "int128";
            cp_ty = ty_option_int128;
            cp_loc = loc;
          };
          {
            cp_name = Var.named "uint128";
            cp_ty = ty_option_uint128;
            cp_loc = loc;
          };
          {
            cp_name = Var.named "range";
            cp_ty = ty_option_int_range;
            cp_loc = loc;
          };
        ];
      cf_return_ty = ty_int;
    }
  in
  let analysis = analyze [ decl_func main ] in
  let graph = analysis.Blorp.Core_dce.dependency_graph in
  let int128_stack_option =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.StackOptionSpecialization
         {
           payload_type = "Int128";
           option_c_type = "blorp_StackOption_Int128";
           payload_c_type = "__int128";
         })
  in
  let uint128_stack_option =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.StackOptionSpecialization
         {
           payload_type = "UInt128";
           option_c_type = "blorp_StackOption_UInt128";
           payload_c_type = "unsigned __int128";
         })
  in
  let range_stack_option =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.StackOptionSpecialization
         {
           payload_type = "Range";
           option_c_type = "blorp_StackOption_Range";
           payload_c_type = "long";
         })
  in
  Alcotest.(check bool)
    "backend int128 stack option typedef edge recorded" true
    (has_edge graph (Blorp.Core_dce.FunctionBody 1) int128_stack_option
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.BackendGeneratedStackOptionLayout));
  Alcotest.(check bool)
    "backend uint128 stack option typedef edge recorded" true
    (has_edge graph (Blorp.Core_dce.FunctionBody 1) uint128_stack_option
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.BackendGeneratedStackOptionLayout));
  Alcotest.(check bool)
    "backend range stack option typedef edge recorded" true
    (has_edge graph (Blorp.Core_dce.FunctionBody 1) range_stack_option
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.BackendGeneratedStackOptionLayout))

let test_dependency_graph_records_runtime_stack_result_layout_artifacts () =
  let main =
    {
      (func 1 "main") with
      cf_params =
        [
          {
            cp_name = Var.named "erased";
            cp_ty = ty_result_int_int;
            cp_loc = loc;
          };
          {
            cp_name = Var.named "managed";
            cp_ty = ty_result_int_string;
            cp_loc = loc;
          };
        ];
      cf_return_ty = ty_int;
    }
  in
  let analysis = analyze [ decl_func main ] in
  let graph = analysis.Blorp.Core_dce.dependency_graph in
  let erased_result_layout =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.StackResultSpecialization
         {
           c_type = "blorp_StackResult";
           layout = Blorp.Core_dce.StackResultErased;
         })
  in
  let managed_result_layout =
    Blorp.Core_dce.GeneratedArtifactDecl
      (Blorp.Core_dce.StackResultSpecialization
         {
           c_type = "blorp_StackResult";
           layout = Blorp.Core_dce.StackResultManaged;
         })
  in
  Alcotest.(check bool)
    "runtime erased stack result layout edge recorded" true
    (has_edge graph (Blorp.Core_dce.FunctionBody 1) erased_result_layout
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.RuntimeOwnedStackResultLayout));
  Alcotest.(check bool)
    "runtime managed stack result layout edge recorded" true
    (has_edge graph (Blorp.Core_dce.FunctionBody 1) managed_result_layout
       (Blorp.Core_dce.GeneratedArtifactDependency
          Blorp.Core_dce.RuntimeOwnedStackResultLayout))

let suite =
  [
    ( "function_reachability",
      [
        Alcotest.test_case "prunes unreachable concrete function" `Quick
          test_prunes_unreachable_concrete_function;
        Alcotest.test_case "keeps private reachable function" `Quick
          test_keeps_private_reachable_function;
        Alcotest.test_case "keeps closure target" `Quick
          test_keeps_function_referenced_by_closure_create;
        Alcotest.test_case "global initializer roots functions" `Quick
          test_global_initializer_roots_reachable_functions;
        Alcotest.test_case "unresolved user call fails closed" `Quick
          test_unresolved_user_call_identity_fails_closed;
        Alcotest.test_case "fail-closed analysis retains generic templates"
          `Quick test_fail_closed_retains_generic_templates;
        Alcotest.test_case "keeps non-concrete functions" `Quick
          test_keeps_non_concrete_functions;
        Alcotest.test_case "prunes non-runtime generic function templates"
          `Quick test_prunes_non_runtime_generic_function_templates;
        Alcotest.test_case "prunes unreachable impl methods" `Quick
          test_prunes_unreachable_impl_methods;
        Alcotest.test_case "prunes empty concrete impl declarations" `Quick
          test_prunes_empty_concrete_impl_declarations;
        Alcotest.test_case "prunes non-runtime generic impl templates" `Quick
          test_prunes_non_runtime_generic_impl_templates;
        Alcotest.test_case "custom dict constructor roots callbacks" `Quick
          test_custom_dict_constructor_roots_hash_callbacks;
        Alcotest.test_case "custom set constructor roots callbacks" `Quick
          test_custom_set_constructor_roots_hash_callbacks;
        Alcotest.test_case "list to_string roots callback" `Quick
          test_list_to_string_roots_stringable_callback;
        Alcotest.test_case "prunes unreachable monomorphic type declarations"
          `Quick test_prunes_unreachable_monomorphic_type_declarations;
        Alcotest.test_case "retains generic type templates" `Quick
          test_retains_generic_type_templates;
        Alcotest.test_case "retains global ABI type layout anchors" `Quick
          test_retains_global_abi_type_layout_anchors;
        Alcotest.test_case "dependency graph records roots and edges" `Quick
          test_dependency_graph_records_roots_and_edges;
        Alcotest.test_case "dependency graph records type edges" `Quick
          test_dependency_graph_records_type_edges;
        Alcotest.test_case "dependency graph records runtime artifact edges"
          `Quick test_dependency_graph_records_runtime_artifact_edges;
        Alcotest.test_case "dependency graph skips generic runtime artifacts"
          `Quick test_dependency_graph_skips_generic_runtime_artifacts;
        Alcotest.test_case
          "dependency graph records record erased-field release mask artifacts"
          `Quick
          test_dependency_graph_records_record_erased_field_release_mask_artifacts;
        Alcotest.test_case
          "dependency graph records runtime builtin lifecycle artifacts" `Quick
          test_dependency_graph_records_runtime_builtin_lifecycle_artifacts;
        Alcotest.test_case
          "dependency graph records tag and singleton artifacts" `Quick
          test_dependency_graph_records_tag_and_singleton_artifacts;
        Alcotest.test_case
          "dependency graph records source stack option layout artifacts" `Quick
          test_dependency_graph_records_source_stack_option_layout_artifacts;
        Alcotest.test_case
          "dependency graph records runtime stack option layout artifacts"
          `Quick
          test_dependency_graph_records_runtime_stack_option_layout_artifacts;
        Alcotest.test_case
          "dependency graph records backend stack option layout artifacts"
          `Quick
          test_dependency_graph_records_backend_stack_option_layout_artifacts;
        Alcotest.test_case
          "dependency graph records runtime stack result layout artifacts"
          `Quick
          test_dependency_graph_records_runtime_stack_result_layout_artifacts;
      ] );
  ]
