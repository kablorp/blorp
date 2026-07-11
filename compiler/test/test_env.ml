(** Unit tests for Env module *)

open Blorp.Ast
open Blorp.Types
open Blorp.Env
module Generic_params = Blorp.Generic_params

(* ============================================================================
   Helpers
   ============================================================================ *)

let check_true msg b = Alcotest.(check bool) msg true b
let check_false msg b = Alcotest.(check bool) msg false b
let trait_ref = Generic_params.trait_ref
let trait_ref_name = Generic_params.trait_ref_name
let trait_ref_names = Generic_params.trait_ref_names
let make_bound_type_param = Generic_params.make_bound_type_param

let unbounded_type_params names =
  List.map (fun name -> make_bound_type_param name []) names

let check_some msg = function
  | Some _ -> Alcotest.(check bool) msg true true
  | None -> Alcotest.fail (msg ^ ": expected Some, got None")

let check_none msg = function
  | Some _ -> Alcotest.fail (msg ^ ": expected None, got Some")
  | None -> Alcotest.(check bool) msg true true

let range_refinement upper_bound =
  let upper =
    match Blorp.Refinement.range_upper_lit upper_bound with
    | Some upper -> upper
    | None -> Alcotest.fail "expected valid range upper"
  in
  let proof =
    match
      Blorp.Refinement.make_range_proof_with_source
        ~source:Blorp.Refinement.ProofSourceCondition ~range_start:0
        ~range_upper:upper
    with
    | Some proof -> proof
    | None -> Alcotest.fail "expected valid range proof"
  in
  (Blorp.Refinement.range_binding proof, proof)

(* ============================================================================
   Basic scope and lookup
   ============================================================================ *)

let test_empty_env () =
  check_none "empty lookup" (lookup (empty ()) "x");
  check_none "empty var type" (get_var_type (empty ()) "x")

let test_add_and_lookup_var () =
  let env = add_var (empty ()) "x" ty_int () in
  check_some "found x" (lookup env "x");
  match get_var_type env "x" with
  | Some ty -> check_true "x : Int" (types_equal ty ty_int)
  | None -> Alcotest.fail "x not found"

let test_add_var_preserves_refinement_metadata () =
  let refinement, proof = range_refinement 5 in
  let env = add_var (empty ()) "i" (TyRange (TyConstInt 5)) ~refinement () in
  match get_var_refinement env "i" with
  | Some refinement -> (
      match Blorp.Refinement.binding_range_proof refinement with
      | Some actual -> check_true "range proof preserved" (actual = proof)
      | None -> Alcotest.fail "expected range refinement")
  | None -> Alcotest.fail "expected variable refinement metadata"

let test_set_var_refinement_updates_nearest_binding () =
  let refinement, proof = range_refinement 7 in
  let env = add_var (empty ()) "i" ty_int () in
  let env = push_scope env in
  let env = add_var env "i" ty_int ~origin:ForLoopVar () in
  let env =
    match set_var_refinement env "i" refinement with
    | Some env -> env
    | None -> Alcotest.fail "expected refinement update"
  in
  match get_var_refinement env "i" with
  | Some refinement -> (
      match Blorp.Refinement.binding_range_proof refinement with
      | Some actual -> check_true "nearest binding updated" (actual = proof)
      | None -> Alcotest.fail "expected nearest binding refinement")
  | None -> Alcotest.fail "expected nearest binding metadata"

let test_set_var_refinement_rejects_non_variable () =
  let refinement, _ = range_refinement 3 in
  let env = add_func (empty ()) "f" (ty_func [] ty_int) () in
  check_none "function is not a variable"
    (set_var_refinement env "f" refinement)

let test_add_and_lookup_func () =
  let ft = ty_func [ ty_int ] ty_bool in
  let env = add_func (empty ()) "is_positive" ft ~purity:Pure () in
  match get_func_info env "is_positive" with
  | Some (ty, _, purity) ->
      check_true "func type" (types_equal ty ft);
      check_true "purity" (purity = Pure)
  | None -> Alcotest.fail "is_positive not found"

let test_scope_shadowing () =
  let env = add_var (empty ()) "x" ty_int () in
  let env = push_scope env in
  let env = add_var env "x" ty_string () in
  (* Inner scope should shadow *)
  match get_var_type env "x" with
  | Some ty -> check_true "shadowed x : String" (types_equal ty ty_string)
  | None -> Alcotest.fail "x not found"

let test_lookup_in_current_scope () =
  let env = add_var (empty ()) "x" ty_int () in
  let env = push_scope env in
  (* x is in outer scope, not current *)
  check_none "not in current scope" (lookup_in_current_scope env "x");
  let env = add_var env "y" ty_string () in
  check_some "y in current scope" (lookup_in_current_scope env "y")

let test_lookup_traverses_scopes () =
  let env = add_var (empty ()) "outer" ty_int () in
  let env = push_scope env in
  let env = add_var env "inner" ty_string () in
  check_some "inner found" (lookup env "inner");
  check_some "outer found" (lookup env "outer")

(* ============================================================================
   Type declarations
   ============================================================================ *)

let test_add_union_type () =
  let variants =
    [
      {
        variant_name = "Some";
        variant_fields = [ TyVar "T" ];
        variant_tag = 0;
        variant_loc = dummy_loc;
        variant_def_id = None;
      };
      {
        variant_name = "None";
        variant_fields = [];
        variant_tag = 1;
        variant_loc = dummy_loc;
        variant_def_id = None;
      };
    ]
  in
  let env = add_type (empty ()) "Option" [ "T" ] variants in
  check_some "Option type" (get_type_decl env "Option");
  (* Constructors should also be registered *)
  check_some "Some constructor" (get_constructor env "Some");
  check_some "None constructor" (get_constructor env "None");
  check_none "nonexistent" (get_constructor env "Just")

let test_constructor_info () =
  let variants =
    [
      {
        variant_name = "Ok";
        variant_fields = [ TyVar "T" ];
        variant_tag = 0;
        variant_loc = dummy_loc;
        variant_def_id = None;
      };
      {
        variant_name = "Err";
        variant_fields = [ TyVar "E" ];
        variant_tag = 1;
        variant_loc = dummy_loc;
        variant_def_id = None;
      };
    ]
  in
  let env = add_type (empty ()) "Result" [ "T"; "E" ] variants in
  match get_constructor env "Ok" with
  | Some (parent, type_params, fields, tag) ->
      Alcotest.(check string) "parent" "Result" parent;
      Alcotest.(check int) "tag" 0 tag;
      Alcotest.(check int) "type_params" 2 (List.length type_params);
      Alcotest.(check int) "fields" 1 (List.length fields)
  | None -> Alcotest.fail "Ok not found"

let test_type_kind_preserved () =
  let env =
    empty () |> fun env ->
    add_type env "Message" [] [] ~kind:TypeUnion |> fun env ->
    add_type env "Color" [] [] ~kind:TypeEnum |> fun env ->
    add_type env "Int" [] [] ~kind:TypeBuiltin |> fun env ->
    add_type env "FileReader" [] [] ~kind:TypeResource
  in
  Alcotest.(check bool)
    "union kind" true
    (get_type_kind env "Message" = Some TypeUnion);
  Alcotest.(check bool)
    "enum kind" true
    (get_type_kind env "Color" = Some TypeEnum);
  Alcotest.(check bool)
    "builtin kind" true
    (get_type_kind env "Int" = Some TypeBuiltin);
  Alcotest.(check bool)
    "resource kind" true
    (get_type_kind env "FileReader" = Some TypeResource)

(* ============================================================================
   Records
   ============================================================================ *)

let test_add_record () =
  let fields =
    [
      { field_name = "x"; field_type = ty_int; field_loc = dummy_loc };
      { field_name = "y"; field_type = ty_int; field_loc = dummy_loc };
    ]
  in
  let env = add_record (empty ()) "Point" [] fields () in
  check_some "Point record" (get_record env "Point");
  check_false "Point is not value type" (is_value_record env "Point")

let test_add_struct () =
  let fields =
    [ { field_name = "x"; field_type = ty_float; field_loc = dummy_loc } ]
  in
  let env = add_record (empty ()) "Vec1" [] fields ~is_value:true () in
  check_true "Vec1 is value type" (is_value_record env "Vec1")

(* ============================================================================
   Type aliases
   ============================================================================ *)

let test_add_and_resolve_alias () =
  let env = add_alias (empty ()) "Str" [] ty_string in
  match get_alias env "Str" with
  | Some ([], target) ->
      check_true "Str -> String" (types_equal target ty_string)
  | _ -> Alcotest.fail "Str alias not found"

let test_resolve_alias_recursive () =
  let env = add_alias (empty ()) "A" [] (TyNamed ("B", [])) in
  let env = add_alias env "B" [] ty_int in
  let resolved = resolve_alias env (TyNamed ("A", [])) in
  check_true "A -> B -> Int" (types_equal resolved ty_int)

let test_resolve_alias_cycle () =
  (* A -> B, B -> A: should not loop *)
  let env = add_alias (empty ()) "A" [] (TyNamed ("B", [])) in
  let env = add_alias env "B" [] (TyNamed ("A", [])) in
  let _resolved = resolve_alias env (TyNamed ("A", [])) in
  check_true "terminates" true

let test_resolve_alias_with_params () =
  (* type Ints = List[Int] *)
  let env = add_alias (empty ()) "Ints" [] (TyNamed ("List", [ ty_int ])) in
  let resolved = resolve_alias env (TyNamed ("Ints", [])) in
  check_true "Ints -> List[Int]"
    (types_equal resolved (TyNamed ("List", [ ty_int ])))

let test_resolve_alias_in_type_arguments () =
  let env =
    add_alias (empty ()) "XmlNode" [] (TyNamed ("std/xml::XmlNode", []))
  in
  let resolved =
    resolve_alias env
      (TyNamed ("Result", [ TyNamed ("XmlNode", []); ty_string ]))
  in
  check_true "aliases resolve inside type arguments"
    (types_equal resolved
       (TyNamed ("Result", [ TyNamed ("std/xml::XmlNode", []); ty_string ])))

let test_resolve_alias_in_array_element () =
  let env = add_alias (empty ()) "Node" [] ty_string in
  let resolved =
    resolve_alias env (TyArray (TyNamed ("Node", []), [ TyConstInt 3 ]))
  in
  check_true "aliases resolve inside array elements"
    (types_equal resolved (TyArray (ty_string, [ TyConstInt 3 ])))

let test_disambiguate_nominal_dim_application () =
  let env =
    add_alias (empty ()) "FloatRow" [ "#N" ]
      (TyArray (ty_float, [ TyVar "#N" ]))
  in
  let parsed = TyArray (TyNamed ("FloatRow", []), [ TyConstInt 2 ]) in
  let resolved =
    parsed |> disambiguate_nominal_dim_application env |> resolve_alias env
  in
  check_true "FloatRow[#2] is an alias application, not a nested array"
    (types_equal resolved (TyArray (ty_float, [ TyConstInt 2 ])))

(* ============================================================================
   Function context
   ============================================================================ *)

let test_enter_function () =
  let env = enter_function (empty ()) "my_func" true [ "T"; "U" ] in
  Alcotest.(check (option string))
    "current func" (Some "my_func") env.current_function;
  check_true "pure" env.current_function_pure;
  check_true "T in scope" (List.mem "T" (get_type_params env));
  check_true "U in scope" (List.mem "U" (get_type_params env))

(* ============================================================================
   Trait functions and bounds
   ============================================================================ *)

let test_trait_functions () =
  let env = add_trait_function (empty ()) "to_string" "Stringable" in
  Alcotest.(check (option string))
    "trait lookup" (Some "Stringable")
    (get_function_trait env "to_string");
  check_none "unknown func" (get_function_trait env "unknown")

let test_type_param_bounds_from_structured_params () =
  Alcotest.(check string)
    "encoded param name" "T"
    (type_param_name "T:Stringable+Showable");
  Alcotest.(check (list string))
    "encoded param names" [ "T"; "U" ]
    (type_param_names [ "T:Stringable"; "U" ]);
  let env =
    set_type_param_bounds (empty ())
      [
        Generic_params.make_bound_type_param "T" [ "Stringable" ];
        Generic_params.make_bound_type_param "U" [];
      ]
  in
  check_true "setter records structured bound"
    (has_trait_bound env "T" "Stringable");
  check_false "setter keeps unbounded params empty"
    (has_trait_bound env "U" "Stringable")

let test_type_param_bounds () =
  let bounds =
    [
      make_bound_type_param "T" [ "Stringable"; "Showable" ];
      make_bound_type_param "U" [ "Numeric" ];
    ]
  in
  let env = set_type_param_bounds (empty ()) bounds in
  check_true "T has Stringable" (has_trait_bound env "T" "Stringable");
  check_true "T has Showable" (has_trait_bound env "T" "Showable");
  check_false "T no Numeric" (has_trait_bound env "T" "Numeric");
  check_true "U has Numeric" (has_trait_bound env "U" "Numeric")

let test_trait_obligation_satisfaction () =
  let env =
    set_type_param_bounds (empty ())
      [ make_bound_type_param "T" [ "Stringable" ] ]
  in
  let obligation =
    { obligation_type = TyVar "T"; obligation_trait = trait_ref "Stringable" }
  in
  check_true "bounded type parameter satisfies obligation"
    (type_satisfies_trait_obligation env obligation)

let test_trait_obligation_respects_declared_type_names () =
  let env =
    set_type_param_bounds (empty ())
      [ make_bound_type_param "T" [ "Stringable" ] ]
  in
  let env = add_record env "T" [] [] () in
  let obligation =
    {
      obligation_type = TyNamed ("T", []);
      obligation_trait = trait_ref "Stringable";
    }
  in
  check_false "declared type T is not treated as bound type parameter"
    (type_satisfies_trait_obligation env obligation)

let trait_obligation_resolution_name = function
  | TraitObligationSatisfied -> "satisfied"
  | TraitObligationUnsatisfied -> "unsatisfied"
  | TraitObligationDeferred -> "deferred"

let check_trait_obligation_resolution msg expected actual =
  Alcotest.(check string)
    msg
    (trait_obligation_resolution_name expected)
    (trait_obligation_resolution_name actual)

let test_trait_obligations_for_bound_type_param () =
  let param = make_bound_type_param "T" [ "Equatable"; "Stringable" ] in
  let obligations = trait_obligations_for_bound_type_param param ty_int in
  Alcotest.(check (list string))
    "obligation traits"
    [ "Equatable"; "Stringable" ]
    (List.map
       (fun obligation -> trait_ref_name obligation.obligation_trait)
       obligations);
  List.iter
    (fun obligation ->
      check_true "obligation type is concrete substitution"
        (types_equal ty_int obligation.obligation_type))
    obligations

let test_resolve_trait_obligation_states () =
  let env =
    set_type_param_bounds (empty ())
      [ make_bound_type_param "T" [ "Stringable" ] ]
  in
  check_trait_obligation_resolution "bounded type parameter satisfies"
    TraitObligationSatisfied
    (resolve_trait_obligation env (trait_obligation (TyVar "T") "Stringable"));

  let env_with_declared_t = add_record env "T" [] [] () in
  check_trait_obligation_resolution "declared concrete T is unsatisfied"
    TraitObligationUnsatisfied
    (resolve_trait_obligation env_with_declared_t
       (trait_obligation (TyNamed ("T", [])) "Stringable"));

  check_trait_obligation_resolution "unresolved type variable defers"
    TraitObligationDeferred
    (resolve_trait_obligation env (trait_obligation (TyVar "U") "Stringable"))

let test_trait_obligation_satisfies_named_type_param () =
  let env = enter_function (empty ()) "f" true [ "Item" ] in
  let env =
    set_type_param_bounds env [ make_bound_type_param "Item" [ "Stringable" ] ]
  in
  check_trait_obligation_resolution "named type parameter satisfies bound"
    TraitObligationSatisfied
    (resolve_trait_obligation env
       (trait_obligation (TyNamed ("Item", [])) "Stringable"))

let test_trait_obligation_structured_bound_var_is_not_deferred () =
  let env = empty () in
  let param = make_bound_type_param "Item" [ "Stringable" ] in
  check_trait_obligation_resolution "structured bound var satisfies own bound"
    TraitObligationSatisfied
    (resolve_trait_obligation env
       (trait_obligation (TyBoundVar param) "Stringable"));
  check_trait_obligation_resolution
    "structured bound var missing bound is unsatisfied"
    TraitObligationUnsatisfied
    (resolve_trait_obligation env
       (trait_obligation (TyBoundVar param) "Numeric"))

let test_resolve_trait_obligation_from_impl_and_supertrait_bound () =
  let env =
    add_impl (empty ())
      {
        ii_def_id = 0;
        ii_trait = "Stringable";
        ii_for_type = ty_int;
        ii_bounds = [];
        ii_is_builtin = false;
        ii_loc = None;
      }
  in
  check_trait_obligation_resolution "concrete impl satisfies"
    TraitObligationSatisfied
    (resolve_trait_obligation env (trait_obligation ty_int "Stringable"));

  let child_trait =
    {
      td_def_id = 0;
      td_name = "Child";
      td_type_params = [];
      td_supertraits = [ "Parent" ];
      td_methods = [];
      td_loc = None;
      td_module_path = None;
    }
  in
  let env = add_trait (empty ()) child_trait in
  let env =
    set_type_param_bounds env [ make_bound_type_param "T" [ "Child" ] ]
  in
  check_trait_obligation_resolution "supertrait bound satisfies"
    TraitObligationSatisfied
    (resolve_trait_obligation env (trait_obligation (TyVar "T") "Parent"))

let check_obligation_trait msg expected = function
  | None -> Alcotest.fail (msg ^ ": expected an unsatisfied obligation")
  | Some obligation ->
      Alcotest.(check string)
        msg expected
        (trait_ref_name obligation.obligation_trait)

let test_find_unsatisfied_trait_obligation () =
  let env =
    add_impl (empty ())
      {
        ii_def_id = 0;
        ii_trait = "Stringable";
        ii_for_type = ty_int;
        ii_bounds = [];
        ii_is_builtin = false;
        ii_loc = None;
      }
  in
  let obligations =
    [
      trait_obligation ty_int "Stringable";
      trait_obligation ty_string "Stringable";
    ]
  in
  check_obligation_trait "finds first unsatisfied obligation" "Stringable"
    (find_unsatisfied_trait_obligation env obligations);

  let obligations =
    [
      trait_obligation (TyVar "U") "Stringable";
      trait_obligation ty_int "Stringable";
    ]
  in
  check_none "deferred obligations do not block"
    (find_unsatisfied_trait_obligation env obligations)

(* ============================================================================
   Trait definitions and impls
   ============================================================================ *)

let test_trait_registration () =
  let trait =
    {
      td_def_id = 0;
      td_name = "Stringable";
      td_type_params = [];
      td_supertraits = [];
      td_methods =
        [
          {
            tm_name = "to_string";
            tm_params = [ TySelf ];
            tm_return = ty_string;
            tm_is_pure = true;
            tm_has_default = false;
            tm_default_body = None;
            tm_param_names = [];
          };
        ];
      td_loc = None;
      td_module_path = None;
    }
  in
  let env = add_trait (empty ()) trait in
  check_some "found trait" (get_trait env "Stringable");
  check_none "unknown trait" (get_trait env "Unknown")

(* Step 3: when a trait is registered in the session-scoped index but
   NOT in the per-file [env.traits], [get_trait] must still find it via
   the session fallback. This is the core of uniform trait-inheritance
   resolution — it lets a file that doesn't [import: traits] still see
   [Orderable: Equatable] once the [traits] module has been loaded. *)

let test_get_trait_falls_back_to_session () =
  let sess = Blorp.Session.create () in
  let trait : trait_decl =
    {
      trait_name = "Comparable";
      trait_type_params = [];
      trait_supertraits = [ "Equatable" ];
      trait_methods = [];
    }
  in
  let m : Blorp.Session.loaded_module =
    {
      name = "test/comparable_mod";
      path = "<test>";
      origin = Blorp.Session.User_module;
      decls =
        [ { decl_desc = DTrait trait; decl_loc = dummy_loc; decl_doc = None } ];
      exports = [];
      surface = None;
      typed_decls = None;
      typed_import_bindings = None;
    }
  in
  Hashtbl.add sess.module_cache m.name m;
  Blorp.Session.register_module_traits sess m;
  (* [empty] has nothing in env.traits — the only path to finding
     Comparable is the session fallback. *)
  Blorp.Session.with_current sess (fun () ->
      match get_trait (empty ()) "Comparable" with
      | None -> Alcotest.fail "expected session fallback to find Comparable"
      | Some td ->
          Alcotest.(check string) "name" "Comparable" td.td_name;
          Alcotest.(check (list string))
            "supertraits" [ "Equatable" ] td.td_supertraits;
          Alcotest.(check (option string))
            "module path threaded through" (Some "test/comparable_mod")
            td.td_module_path)

(* Step 4: conflict detection for duplicate trait declarations.

   Two modules that independently declare the same trait name must be
   caught when their defs differ structurally (different supertraits,
   different method signatures). Structurally-equal redeclarations are
   the idempotent case and must NOT error — that's the normal path for
   a single module being imported via multiple chains. *)

let mk_simple_td ?(supertraits = []) ?(methods = []) name : trait_def =
  {
    td_def_id = 0;
    td_name = name;
    td_type_params = [];
    td_supertraits = supertraits;
    td_methods = methods;
    td_loc = None;
    td_module_path = None;
  }

let test_structurally_equal_identical () =
  let a = mk_simple_td "Foo" ~supertraits:[ "A"; "B" ] in
  let b = mk_simple_td "Foo" ~supertraits:[ "A"; "B" ] in
  check_true "identical defs are equal" (trait_defs_structurally_equal a b)

let test_structurally_equal_ignores_location () =
  let a = mk_simple_td "Foo" in
  let b = { a with td_loc = Some dummy_loc; td_module_path = Some "x/y" } in
  check_true "loc/module_path don't affect equality"
    (trait_defs_structurally_equal a b)

let test_structurally_unequal_supertraits () =
  let a = mk_simple_td "Foo" ~supertraits:[ "A" ] in
  let b = mk_simple_td "Foo" ~supertraits:[ "B" ] in
  check_false "different supertraits" (trait_defs_structurally_equal a b)

let test_structurally_unequal_methods () =
  let m1 =
    {
      tm_name = "f";
      tm_params = [ TySelf ];
      tm_return = ty_int;
      tm_is_pure = true;
      tm_has_default = false;
      tm_default_body = None;
      tm_param_names = [];
    }
  in
  let m2 = { m1 with tm_return = ty_string } in
  let a = mk_simple_td "Foo" ~methods:[ m1 ] in
  let b = mk_simple_td "Foo" ~methods:[ m2 ] in
  check_false "different method return type" (trait_defs_structurally_equal a b)

let test_try_add_trait_idempotent () =
  let trait = mk_simple_td "Dup" ~supertraits:[ "X" ] in
  let env = add_trait (empty ()) trait in
  match try_add_trait env trait with
  | Ok env' ->
      (* Idempotent: the traits list shouldn't grow. *)
      Alcotest.(check int)
        "no duplicate entry" 1
        (List.length (List.filter (fun t -> t.td_name = "Dup") env'.traits))
  | Error _ -> Alcotest.fail "expected Ok for identical redeclaration"

let test_try_add_trait_stub_replaced_by_decl () =
  (* env_builtins stubs (td_loc=None, td_module_path=None) must yield
     to the authoritative declaration from std/traits.brp rather than
     conflict, even when the method lists differ. Without this, a
     richer built-in stub (FloatingPoint with 33 methods) would clash
     with the lighter user-facing trait (15 methods) in std/traits.brp. *)
  let stub =
    mk_simple_td "F" ~supertraits:[ "A" ]
      ~methods:
        [
          {
            tm_name = "extra";
            tm_params = [ TySelf ];
            tm_return = ty_int;
            tm_is_pure = true;
            tm_has_default = false;
            tm_default_body = None;
            tm_param_names = [];
          };
        ]
  in
  let user_decl =
    {
      (mk_simple_td "F" ~supertraits:[ "B" ]) with
      td_loc = Some dummy_loc;
      td_module_path = Some "std/traits";
    }
  in
  let env = add_trait (empty ()) stub in
  match try_add_trait env user_decl with
  | Error _ -> Alcotest.fail "stub should yield to user decl, not conflict"
  | Ok env' ->
      (* The winning entry must be the user's, and there must be no
         duplicate left over. *)
      (match get_trait env' "F" with
      | Some td ->
          Alcotest.(check (list string))
            "user decl wins" [ "B" ] td.td_supertraits
      | None -> Alcotest.fail "expected to find F after replace");
      Alcotest.(check int)
        "no duplicate entries" 1
        (List.length (List.filter (fun t -> t.td_name = "F") env'.traits))

(* Step 5 (Option D): [trait_method_names_transitive] collects method
   names declared on a trait AND all names reachable through its
   supertrait chain. The default-body synthesizer uses this set to
   know which bare-name calls in a default body refer to trait
   methods and should be rewritten into UFCS form. *)

let test_trait_method_names_no_supertraits () =
  let td =
    mk_simple_td "T"
      ~methods:
        [
          {
            tm_name = "a";
            tm_params = [ TySelf ];
            tm_return = ty_int;
            tm_is_pure = true;
            tm_has_default = false;
            tm_default_body = None;
            tm_param_names = [];
          };
          {
            tm_name = "b";
            tm_params = [ TySelf ];
            tm_return = ty_int;
            tm_is_pure = true;
            tm_has_default = false;
            tm_default_body = None;
            tm_param_names = [];
          };
        ]
  in
  let env = add_trait (empty ()) td in
  let names = trait_method_names_transitive env "T" in
  Alcotest.(check (list string))
    "own methods" [ "a"; "b" ] (List.sort compare names)

let test_trait_method_names_walks_supertraits () =
  let super =
    mk_simple_td "Super"
      ~methods:
        [
          {
            tm_name = "inherited";
            tm_params = [ TySelf ];
            tm_return = ty_bool;
            tm_is_pure = true;
            tm_has_default = false;
            tm_default_body = None;
            tm_param_names = [];
          };
        ]
  in
  let child =
    mk_simple_td "Child" ~supertraits:[ "Super" ]
      ~methods:
        [
          {
            tm_name = "own";
            tm_params = [ TySelf ];
            tm_return = ty_int;
            tm_is_pure = true;
            tm_has_default = false;
            tm_default_body = None;
            tm_param_names = [];
          };
        ]
  in
  let env = add_trait (empty ()) super in
  let env = add_trait env child in
  let names = trait_method_names_transitive env "Child" in
  Alcotest.(check (list string))
    "own + inherited" [ "inherited"; "own" ] (List.sort compare names)

let test_trait_method_names_handles_cycle () =
  (* Defensive: a supertrait cycle (ill-formed, but must not hang). *)
  let a =
    mk_simple_td "A" ~supertraits:[ "B" ]
      ~methods:
        [
          {
            tm_name = "fa";
            tm_params = [ TySelf ];
            tm_return = ty_int;
            tm_is_pure = true;
            tm_has_default = false;
            tm_default_body = None;
            tm_param_names = [];
          };
        ]
  in
  let b =
    mk_simple_td "B" ~supertraits:[ "A" ]
      ~methods:
        [
          {
            tm_name = "fb";
            tm_params = [ TySelf ];
            tm_return = ty_int;
            tm_is_pure = true;
            tm_has_default = false;
            tm_default_body = None;
            tm_param_names = [];
          };
        ]
  in
  let env = add_trait (empty ()) a in
  let env = add_trait env b in
  let names = trait_method_names_transitive env "A" in
  Alcotest.(check (list string))
    "both methods, no hang" [ "fa"; "fb" ] (List.sort compare names)

let test_trait_method_names_missing_trait () =
  Alcotest.(check (list string))
    "unknown trait yields empty" []
    (trait_method_names_transitive (empty ()) "Nonexistent")

let test_try_add_trait_conflict () =
  (* Both declarations carry provenance (td_module_path = Some) — the
     stub-replacement path doesn't apply, so the mismatch must surface
     as an error. *)
  let a =
    {
      (mk_simple_td "Clash" ~supertraits:[ "FromA" ]) with
      td_module_path = Some "a/mod";
      td_loc = Some dummy_loc;
    }
  in
  let b =
    {
      (mk_simple_td "Clash" ~supertraits:[ "FromB" ]) with
      td_module_path = Some "b/mod";
      td_loc = Some dummy_loc;
    }
  in
  let env = add_trait (empty ()) a in
  match try_add_trait env b with
  | Ok _ -> Alcotest.fail "expected Error for conflicting redeclaration"
  | Error msg ->
      (* Error message should mention the trait name. Exact text is a
         diagnostic concern tested at the pipeline level. *)
      let contains_substr haystack needle =
        let lh = String.length haystack and ln = String.length needle in
        let rec loop i =
          if i + ln > lh then false
          else if String.sub haystack i ln = needle then true
          else loop (i + 1)
        in
        loop 0
      in
      check_true "error mentions trait name" (contains_substr msg "Clash")

let test_env_traits_win_over_session_fallback () =
  (* A trait registered directly into [env.traits] must take precedence
     over the session fallback even when both exist. This preserves the
     per-file registration path for imports. *)
  let sess = Blorp.Session.create () in
  let session_trait : trait_decl =
    {
      trait_name = "Shared";
      trait_type_params = [];
      trait_supertraits = [ "FromSession" ];
      (* distinct marker *)
      trait_methods = [];
    }
  in
  let m : Blorp.Session.loaded_module =
    {
      name = "sess/mod";
      path = "<test>";
      origin = Blorp.Session.User_module;
      decls =
        [
          {
            decl_desc = DTrait session_trait;
            decl_loc = dummy_loc;
            decl_doc = None;
          };
        ];
      exports = [];
      surface = None;
      typed_decls = None;
      typed_import_bindings = None;
    }
  in
  Hashtbl.add sess.module_cache m.name m;
  Blorp.Session.register_module_traits sess m;
  let env_trait =
    {
      td_def_id = 0;
      td_name = "Shared";
      td_type_params = [];
      td_supertraits = [ "FromEnv" ];
      (* distinct marker *)
      td_methods = [];
      td_loc = None;
      td_module_path = Some "env/direct";
    }
  in
  let env = add_trait (empty ()) env_trait in
  Blorp.Session.with_current sess (fun () ->
      match get_trait env "Shared" with
      | None -> Alcotest.fail "expected to find Shared"
      | Some td ->
          Alcotest.(check (list string))
            "env.traits wins" [ "FromEnv" ] td.td_supertraits)

let test_impl_instance () =
  let impl =
    {
      ii_def_id = 0;
      ii_trait = "Stringable";
      ii_for_type = ty_int;
      ii_bounds = [];
      ii_is_builtin = false;
      ii_loc = None;
    }
  in
  let env = add_impl (empty ()) impl in
  check_true "Int implements Stringable"
    (type_implements_trait env ty_int "Stringable");
  check_false "String doesn't implement Stringable"
    (type_implements_trait env ty_string "Stringable")

let test_generic_impl () =
  let env =
    add_impl (empty ())
      {
        ii_def_id = 0;
        ii_trait = "Stringable";
        ii_for_type = ty_int;
        ii_bounds = [];
        ii_is_builtin = false;
        ii_loc = None;
      }
  in
  let env =
    add_impl env
      {
        ii_def_id = 0;
        ii_trait = "Stringable";
        ii_for_type = ty_string;
        ii_bounds = [];
        ii_is_builtin = false;
        ii_loc = None;
      }
  in
  let impl =
    {
      ii_def_id = 0;
      ii_trait = "Stringable";
      ii_for_type = TyNamed ("List", [ TyVar "T" ]);
      ii_bounds = [ make_bound_type_param "T" [ "Stringable" ] ];
      ii_is_builtin = false;
      ii_loc = None;
    }
  in
  let env = add_impl env impl in
  check_true "List[Int] implements Stringable"
    (type_implements_trait env (TyNamed ("List", [ ty_int ])) "Stringable");
  check_true "List[String] implements Stringable"
    (type_implements_trait env (TyNamed ("List", [ ty_string ])) "Stringable")

(* ============================================================================
   resolve_self
   ============================================================================ *)

let test_resolve_self () =
  let ty = TyFunc { params = [ TySelf ]; return = TySelf; is_pure = true } in
  let resolved = resolve_self ty_int ty in
  let expected =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  check_true "Self -> Int" (types_equal resolved expected)

(* ============================================================================
   Levenshtein distance
   ============================================================================ *)

let test_levenshtein () =
  Alcotest.(check int) "same" 0 (levenshtein "abc" "abc");
  Alcotest.(check int) "insert" 1 (levenshtein "abc" "abcd");
  Alcotest.(check int) "delete" 1 (levenshtein "abcd" "abc");
  Alcotest.(check int) "replace" 1 (levenshtein "abc" "aXc");
  Alcotest.(check int) "empty left" 3 (levenshtein "" "abc");
  Alcotest.(check int) "empty right" 3 (levenshtein "abc" "");
  Alcotest.(check int) "both empty" 0 (levenshtein "" "")

let test_find_similar () =
  let env = add_var (empty ()) "print" ty_string () in
  let env = add_var env "printer" ty_string () in
  let env = add_var env "format" ty_string () in
  (* "pritn" is close to "print" *)
  (match find_similar "pritn" env with
  | Some name -> Alcotest.(check string) "suggestion" "print" name
  | None -> Alcotest.fail "expected suggestion");
  (* "xyzzy" is not close to anything *)
  check_none "no suggestion" (find_similar "xyzzy" env)

(* ============================================================================
   Builtin func detection
   ============================================================================ *)

let test_is_builtin_func () =
  let env =
    add_func (empty ()) "print"
      (ty_func [ ty_string ] ty_void)
      ~origin:Builtin ~purity:Impure ()
  in
  let env = add_func env "my_func" (ty_func [] ty_void) () in
  check_true "print is builtin" (is_builtin_func env "print");
  check_false "my_func is not builtin" (is_builtin_func env "my_func");
  check_false "unknown is not builtin" (is_builtin_func env "unknown")

let test_loop_producer_metadata () =
  let env =
    add_func (empty ()) "enumerate2"
      (ty_func
         [ TyArray (TyVar "T", [ TyVar "#M"; TyVar "#N" ]) ]
         (TyNamed ("List", [ TyTuple [ ty_int; ty_int; TyVar "T" ] ]))
         ~pure:true)
      ~origin:Builtin ~purity:Pure ~loop_producer:LoopProducerEnumerate2 ()
  in
  (match get_func_loop_producer env "enumerate2" with
  | Some LoopProducerEnumerate2 -> ()
  | _ -> Alcotest.fail "expected enumerate2 function loop-producer metadata");
  let env =
    add_func env "indices"
      (ty_func
         [ TyArray (TyVar "T", [ TyVar "#N" ]) ]
         (TyNamed ("List", [ ty_int ]))
         ~pure:true)
      ~origin:Builtin ~purity:Pure ~loop_producer:LoopProducerIndices ()
  in
  (match get_func_loop_producer env "indices" with
  | Some LoopProducerIndices -> ()
  | _ -> Alcotest.fail "expected indices function loop-producer metadata");
  let entry =
    {
      ol_def_id = 0;
      ol_func_type =
        TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true };
      ol_type_params = [];
      ol_param_names = [ None ];
      ol_purity = Pure;
      ol_origin = UserDefined;
      ol_resource_args = RejectResourceArgs;
      ol_module_path = Some "test/mod";
      ol_dim_constraints = [];
      ol_loop_producer = Some LoopProducerWindows;
      ol_debug_only = false;
    }
  in
  let env = add_overload env "windows" entry in
  match get_overloads env "windows" with
  | [ { ol_loop_producer = Some LoopProducerWindows; _ } ] -> ()
  | _ -> Alcotest.fail "expected windows overload loop-producer metadata"

let test_builtin_resource_args_require_explicit_opt_in () =
  let func_ty = ty_func [ TyVar "T" ] (TyVar "T") in
  let env = add_func (empty ()) "builtin_identity" func_ty ~origin:Builtin () in
  (match lookup env "builtin_identity" with
  | Some { kind = FuncSymbol { resource_args; _ }; _ } ->
      check_true "builtin defaults reject resource args"
        (resource_args = RejectResourceArgs)
  | _ -> Alcotest.fail "expected builtin_identity function");
  let env =
    add_func env "borrow_resource" func_ty ~origin:Builtin
      ~resource_args:(AllowResourceArgs ResourceResultDependent) ()
  in
  match lookup env "borrow_resource" with
  | Some { kind = FuncSymbol { resource_args; _ }; _ } ->
      check_true "explicit builtin opt-in allows resource args"
        (resource_args = AllowResourceArgs ResourceResultDependent)
  | _ -> Alcotest.fail "expected borrow_resource function"

(* ============================================================================
   direct_subst
   ============================================================================ *)

let test_direct_subst () =
  (* Single substitution *)
  let result = direct_subst [ ("T", ty_int) ] (TyVar "T") in
  check_true "T -> Int" (types_equal result ty_int);

  (* No chaining: T -> U doesn't follow U -> Int *)
  let result = direct_subst [ ("T", TyVar "U"); ("U", ty_int) ] (TyVar "T") in
  check_true "T -> U (no chain)" (types_equal result (TyVar "U"))

(* ============================================================================
   UFCS method-only functions
   ============================================================================ *)

let test_ufcs_method_add_and_lookup () =
  (* Register a UFCS method: filter(self: List[T], pred) -> List[T] *)
  let filter_type =
    TyFunc
      {
        params =
          [
            TyNamed ("List", [ TyVar "T" ]);
            TyFunc { params = [ TyVar "T" ]; return = ty_bool; is_pure = true };
          ];
        return = TyNamed ("List", [ TyVar "T" ]);
        is_pure = true;
      }
  in
  let entry =
    {
      ol_def_id = 0;
      ol_func_type = filter_type;
      ol_type_params = unbounded_type_params [ "T" ];
      ol_param_names = [ Some "self"; Some "pred" ];
      ol_purity = Pure;
      ol_origin = UserDefined;
      ol_resource_args = RejectResourceArgs;
      ol_dim_constraints = [];
      ol_module_path = Some "std/list";
      ol_loop_producer = None;
      ol_debug_only = false;
    }
  in
  let env = add_ufcs_method (empty ()) "filter" entry in
  (* Should NOT be found by normal lookup *)
  check_none "filter not in normal scope" (lookup env "filter");
  (* Should be found by UFCS lookup with matching type *)
  let matches =
    lookup_ufcs_methods env "filter" (TyNamed ("List", [ ty_int ]))
  in
  check_true "filter found for List[Int]" (List.length matches = 1);
  (* Should NOT match for a different type *)
  let no_match =
    lookup_ufcs_methods env "filter" (TyNamed ("Dict", [ ty_string; ty_int ]))
  in
  check_true "filter not found for Dict" (List.length no_match = 0);
  (* has_ufcs_method *)
  check_true "has filter" (has_ufcs_method env "filter");
  check_false "no map" (has_ufcs_method env "map")

let test_ufcs_method_multiple_types () =
  (* Register filter for List AND filter for Set from different modules *)
  let list_filter =
    {
      ol_def_id = 0;
      ol_func_type =
        TyFunc
          {
            params =
              [
                TyNamed ("List", [ TyVar "T" ]);
                TyFunc
                  { params = [ TyVar "T" ]; return = ty_bool; is_pure = true };
              ];
            return = TyNamed ("List", [ TyVar "T" ]);
            is_pure = true;
          };
      ol_type_params = unbounded_type_params [ "T" ];
      ol_param_names = [];
      ol_purity = Pure;
      ol_origin = UserDefined;
      ol_resource_args = RejectResourceArgs;
      ol_dim_constraints = [];
      ol_module_path = Some "std/list";
      ol_loop_producer = None;
      ol_debug_only = false;
    }
  in
  let set_filter =
    {
      ol_def_id = 0;
      ol_func_type =
        TyFunc
          {
            params =
              [
                TyNamed ("Set", [ TyVar "T" ]);
                TyFunc
                  { params = [ TyVar "T" ]; return = ty_bool; is_pure = true };
              ];
            return = TyNamed ("Set", [ TyVar "T" ]);
            is_pure = true;
          };
      ol_type_params = unbounded_type_params [ "T" ];
      ol_param_names = [];
      ol_purity = Pure;
      ol_origin = UserDefined;
      ol_resource_args = RejectResourceArgs;
      ol_dim_constraints = [];
      ol_module_path = Some "std/set";
      ol_loop_producer = None;
      ol_debug_only = false;
    }
  in
  let env =
    add_ufcs_method
      (add_ufcs_method (empty ()) "filter" list_filter)
      "filter" set_filter
  in
  (* List type matches list version *)
  let list_matches =
    lookup_ufcs_methods env "filter" (TyNamed ("List", [ ty_int ]))
  in
  check_true "list filter" (List.length list_matches = 1);
  check_true "from std/list"
    ((List.hd list_matches).ol_module_path = Some "std/list");
  (* Set type matches set version *)
  let set_matches =
    lookup_ufcs_methods env "filter" (TyNamed ("Set", [ ty_string ]))
  in
  check_true "set filter" (List.length set_matches = 1);
  check_true "from std/set"
    ((List.hd set_matches).ol_module_path = Some "std/set")

(* ============================================================================
   Diagnostic qualification (Track B)
   ============================================================================ *)

(** A trait with a known home module renders as
    ["TraitName (from module)"]. *)
let test_format_trait_name_with_module () =
  let td =
    {
      td_def_id = 0;
      td_name = "MyTrait";
      td_type_params = [];
      td_supertraits = [];
      td_methods = [];
      td_loc = None;
      td_module_path = Some "my/mod";
    }
  in
  let env = add_trait (empty ()) td in
  Alcotest.(check string)
    "qualifies with home module" "MyTrait (from my/mod)"
    (format_trait_name env "MyTrait")

(** A builtin trait ([td_module_path = None]) renders bare. *)
let test_format_trait_name_builtin_unqualified () =
  let td =
    {
      td_def_id = 0;
      td_name = "BuiltinTrait";
      td_type_params = [];
      td_supertraits = [];
      td_methods = [];
      td_loc = None;
      td_module_path = None;
    }
  in
  let env = add_trait (empty ()) td in
  Alcotest.(check string)
    "builtin renders bare" "BuiltinTrait"
    (format_trait_name env "BuiltinTrait")

(** A trait that isn't registered renders bare (no crash). *)
let test_format_trait_name_unknown () =
  Alcotest.(check string)
    "unknown trait renders bare" "Unknown"
    (format_trait_name (empty ()) "Unknown")

(** Overload reference qualifies with the overload's home module
    when [ol_module_path] is set. *)
let test_format_overload_ref_with_module () =
  let entry =
    {
      ol_def_id = 0;
      ol_func_type =
        TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true };
      ol_type_params = [];
      ol_param_names = [ None ];
      ol_purity = Pure;
      ol_origin = Builtin;
      ol_resource_args = RejectResourceArgs;
      ol_module_path = Some "std/list";
      ol_dim_constraints = [];
      ol_loop_producer = None;
      ol_debug_only = false;
    }
  in
  Alcotest.(check string)
    "qualifies with module" "map (from std/list)"
    (format_overload_ref "map" entry)

(** Overload with [ol_module_path = None] (prelude / builtin) renders bare. *)
let test_format_overload_ref_bare () =
  let entry =
    {
      ol_def_id = 0;
      ol_func_type =
        TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true };
      ol_type_params = [];
      ol_param_names = [ None ];
      ol_purity = Pure;
      ol_origin = Builtin;
      ol_resource_args = RejectResourceArgs;
      ol_module_path = None;
      ol_dim_constraints = [];
      ol_loop_producer = None;
      ol_debug_only = false;
    }
  in
  Alcotest.(check string)
    "bare when no module" "length"
    (format_overload_ref "length" entry)

(* ============================================================================
   DefId minting (Track A)
   ============================================================================ *)

(** Successive mints yield distinct, monotonically increasing ids. *)
let test_def_id_mint_unique_within_session () =
  let sess = Blorp.Session.create () in
  let ids = List.init 5 (fun _ -> Blorp.Session.mint_def_id sess) in
  let unique_count = List.length (List.sort_uniq compare ids) in
  Alcotest.(check int) "5 unique ids" 5 unique_count

(** Two independent sessions mint their own id sequences — no
    cross-session sharing of the counter. *)
let test_def_id_per_session_isolation () =
  let sess_a = Blorp.Session.create () in
  let sess_b = Blorp.Session.create () in
  let ida1 = Blorp.Session.mint_def_id sess_a in
  let ida2 = Blorp.Session.mint_def_id sess_a in
  let idb1 = Blorp.Session.mint_def_id sess_b in
  check_true "session A ids differ" (ida1 <> ida2);
  Alcotest.(check int) "session A first id" 0 ida1;
  Alcotest.(check int) "session B first id" 0 idb1

(** An overload entry carries its def_id through the record. *)
let test_overload_entry_carries_def_id () =
  let sess = Blorp.Session.create () in
  let id = Blorp.Session.mint_def_id sess in
  let ft = ty_func [ ty_int ] ty_int in
  let entry =
    {
      ol_def_id = id;
      ol_func_type = ft;
      ol_type_params = [];
      ol_param_names = [ None ];
      ol_purity = Pure;
      ol_origin = UserDefined;
      ol_resource_args = RejectResourceArgs;
      ol_module_path = Some "test/mod";
      ol_dim_constraints = [];
      ol_loop_producer = None;
      ol_debug_only = false;
    }
  in
  Alcotest.(check int) "def_id roundtrip" id entry.ol_def_id

(* ============================================================================
   Trait method name collision detection (Track D)
   ============================================================================ *)

(** Two unrelated traits claiming the same method name should be
    flagged as a collision when the second one tries to register. *)
let test_trait_function_collision_detected () =
  let env = add_trait_function (empty ()) "render" "TraitA" in
  match trait_function_collision env "render" "TraitB" with
  | Some existing ->
      Alcotest.(check string) "existing trait is TraitA" "TraitA" existing
  | None -> Alcotest.fail "expected collision, got None"

(** Re-registering the same method under the same trait is idempotent;
    this is the pattern used by the supertrait sweep in [register_trait]
    and by repeat imports. *)
let test_trait_function_no_collision_same_pair () =
  let env = add_trait_function (empty ()) "render" "TraitA" in
  check_none "same (method, trait) pair is not a collision"
    (trait_function_collision env "render" "TraitA")

(** Different methods registered under the same trait — not a
    collision. *)
let test_trait_function_no_collision_different_method () =
  let env = add_trait_function (empty ()) "render" "TraitA" in
  check_none "different method in same trait is not a collision"
    (trait_function_collision env "describe" "TraitA")

(** A supertrait relationship: registering Orderable after Equatable
    re-registers Equatable's methods under "Equatable" (their
    declaring trait). That's the same (method, trait) pair as already
    present — idempotent, not a collision. *)
let test_trait_function_supertrait_idempotent () =
  let env = add_trait_function (empty ()) "same" "Equatable" in
  (* Orderable's supertrait sweep re-binds "same" under "Equatable" *)
  check_none "supertrait sweep under declaring trait is not a collision"
    (trait_function_collision env "same" "Equatable")

(* ============================================================================
   UFCS cross-module collision detection (Track C)
   ============================================================================ *)

(** Build a UFCS-style overload entry for [name] with the given first-arg
    type, purity, and source module. *)
let make_ufcs_entry ~module_path ~first_param_type ~purity =
  {
    ol_def_id = 0;
    ol_func_type =
      TyFunc
        {
          params = [ first_param_type ];
          return = ty_string;
          is_pure = purity = Pure;
        };
    ol_type_params = [];
    ol_param_names = [ None ];
    ol_purity = purity;
    ol_origin = UserDefined;
    ol_resource_args = RejectResourceArgs;
    ol_module_path = Some module_path;
    ol_dim_constraints = [];
    ol_loop_producer = None;
    ol_debug_only = false;
  }

(** Two modules registering the same method name for the same first-arg
    head type and purity should be flagged as a collision. *)
let test_ufcs_collision_cross_module_same_type () =
  let list_ty = TyNamed ("List", [ TyVar "T" ]) in
  let entry_a =
    make_ufcs_entry ~module_path:"mod/a" ~first_param_type:list_ty ~purity:Pure
  in
  let entry_b =
    make_ufcs_entry ~module_path:"mod/b" ~first_param_type:list_ty ~purity:Pure
  in
  let env = add_ufcs_method (empty ()) "foo" entry_a in
  match ufcs_collision env "foo" entry_b with
  | Some existing ->
      Alcotest.(check (option string))
        "existing module is mod/a" (Some "mod/a") existing.ol_module_path
  | None -> Alcotest.fail "expected collision, got None"

(** Two modules registering the same method name on DIFFERENT first-arg
    head types should not collide — first-arg dispatch resolves them
    unambiguously at call sites. *)
let test_ufcs_no_collision_different_types () =
  let list_ty = TyNamed ("List", [ TyVar "T" ]) in
  let dict_ty = TyNamed ("Dict", [ TyVar "K"; TyVar "V" ]) in
  let entry_a =
    make_ufcs_entry ~module_path:"mod/a" ~first_param_type:list_ty ~purity:Pure
  in
  let entry_b =
    make_ufcs_entry ~module_path:"mod/b" ~first_param_type:dict_ty ~purity:Pure
  in
  let env = add_ufcs_method (empty ()) "foo" entry_a in
  check_none "no collision for different receiver types"
    (ufcs_collision env "foo" entry_b)

(** Same module re-registering the same entry is idempotent, not a
    collision. *)
let test_ufcs_no_collision_same_module () =
  let list_ty = TyNamed ("List", [ TyVar "T" ]) in
  let entry =
    make_ufcs_entry ~module_path:"mod/a" ~first_param_type:list_ty ~purity:Pure
  in
  let env = add_ufcs_method (empty ()) "foo" entry in
  check_none "same module is not a collision" (ufcs_collision env "foo" entry)

(** Pure and impure entries from the SAME module are the designed
    pure/impure pair pattern — not a collision. *)
let test_ufcs_no_collision_pure_impure_same_module () =
  let list_ty = TyNamed ("List", [ TyVar "T" ]) in
  let pure_entry =
    make_ufcs_entry ~module_path:"mod/a" ~first_param_type:list_ty ~purity:Pure
  in
  let impure_entry =
    make_ufcs_entry ~module_path:"mod/a" ~first_param_type:list_ty
      ~purity:Impure
  in
  let env = add_ufcs_method (empty ()) "foo" pure_entry in
  check_none "pure/impure pair in same module is not a collision"
    (ufcs_collision env "foo" impure_entry)

(** Different modules WITH different purities still counts as
    separately dispatchable — no collision. *)
let test_ufcs_no_collision_different_purity () =
  let list_ty = TyNamed ("List", [ TyVar "T" ]) in
  let pure_a =
    make_ufcs_entry ~module_path:"mod/a" ~first_param_type:list_ty ~purity:Pure
  in
  let impure_b =
    make_ufcs_entry ~module_path:"mod/b" ~first_param_type:list_ty
      ~purity:Impure
  in
  let env = add_ufcs_method (empty ()) "foo" pure_a in
  check_none "different purities across modules are not a collision"
    (ufcs_collision env "foo" impure_b)

let test_ufcs_method_pure_impure_overloads () =
  (* Register both pure and impure map *)
  let pure_map =
    {
      ol_def_id = 0;
      ol_func_type =
        TyFunc
          {
            params =
              [
                TyNamed ("List", [ TyVar "T" ]);
                TyFunc
                  { params = [ TyVar "T" ]; return = TyVar "U"; is_pure = true };
              ];
            return = TyNamed ("List", [ TyVar "U" ]);
            is_pure = true;
          };
      ol_type_params = unbounded_type_params [ "T"; "U" ];
      ol_param_names = [];
      ol_purity = Pure;
      ol_origin = UserDefined;
      ol_resource_args = RejectResourceArgs;
      ol_dim_constraints = [];
      ol_module_path = Some "std/list";
      ol_loop_producer = None;
      ol_debug_only = false;
    }
  in
  let impure_map =
    {
      ol_def_id = 0;
      ol_func_type =
        TyFunc
          {
            params =
              [
                TyNamed ("List", [ TyVar "T" ]);
                TyFunc
                  {
                    params = [ TyVar "T" ];
                    return = TyVar "U";
                    is_pure = false;
                  };
              ];
            return = TyNamed ("List", [ TyVar "U" ]);
            is_pure = false;
          };
      ol_type_params = unbounded_type_params [ "T"; "U" ];
      ol_param_names = [];
      ol_purity = Impure;
      ol_origin = UserDefined;
      ol_resource_args = RejectResourceArgs;
      ol_dim_constraints = [];
      ol_module_path = Some "std/list";
      ol_loop_producer = None;
      ol_debug_only = false;
    }
  in
  let env =
    add_ufcs_method (add_ufcs_method (empty ()) "map" pure_map) "map" impure_map
  in
  (* Both should be returned for List type *)
  let matches = lookup_ufcs_methods env "map" (TyNamed ("List", [ ty_int ])) in
  check_true "both overloads found" (List.length matches = 2)

(* ============================================================================
   Phase 2.7 tasks 48/49 — overload tiebreak by callback purity
   ============================================================================ *)

(** Build the canonical pure/impure overload pair for [flat_map] —
    used by the [select_overload_for_args] tests below. *)
let pure_impure_pair_overloads =
  let pure_overload =
    {
      ol_def_id = 0;
      ol_func_type =
        TyFunc
          {
            params =
              [
                TyNamed ("List", [ TyVar "T" ]);
                TyFunc
                  {
                    params = [ TyVar "T" ];
                    return = TyNamed ("List", [ TyVar "U" ]);
                    is_pure = true;
                  };
              ];
            return = TyNamed ("List", [ TyVar "U" ]);
            is_pure = true;
          };
      ol_type_params = unbounded_type_params [ "T"; "U" ];
      ol_param_names = [];
      ol_purity = Pure;
      ol_origin = UserDefined;
      ol_resource_args = RejectResourceArgs;
      ol_dim_constraints = [];
      ol_module_path = Some "std/list";
      ol_loop_producer = None;
      ol_debug_only = false;
    }
  in
  let impure_overload =
    {
      ol_def_id = 0;
      ol_func_type =
        TyFunc
          {
            params =
              [
                TyNamed ("List", [ TyVar "T" ]);
                TyFunc
                  {
                    params = [ TyVar "T" ];
                    return = TyNamed ("List", [ TyVar "U" ]);
                    is_pure = false;
                  };
              ];
            return = TyNamed ("List", [ TyVar "U" ]);
            is_pure = false;
          };
      ol_type_params = unbounded_type_params [ "T"; "U" ];
      ol_param_names = [];
      ol_purity = Impure;
      ol_origin = UserDefined;
      ol_resource_args = RejectResourceArgs;
      ol_dim_constraints = [];
      ol_module_path = Some "std/list_impure";
      ol_loop_producer = None;
      ol_debug_only = false;
    }
  in
  [ pure_overload; impure_overload ]

let test_select_picks_impure_for_impure_cb () =
  let list_int = TyNamed ("List", [ ty_int ]) in
  let impure_cb =
    TyFunc
      {
        params = [ ty_int ];
        return = TyNamed ("List", [ ty_int ]);
        is_pure = false;
      }
  in
  match
    select_overload_for_args pure_impure_pair_overloads [ list_int; impure_cb ]
  with
  | Some entry -> check_true "picked impure overload" (entry.ol_purity = Impure)
  | None -> Alcotest.fail "expected unique impure overload, got None"

let test_select_picks_pure_for_pure_cb () =
  let list_int = TyNamed ("List", [ ty_int ]) in
  let pure_cb =
    TyFunc
      {
        params = [ ty_int ];
        return = TyNamed ("List", [ ty_int ]);
        is_pure = true;
      }
  in
  match
    select_overload_for_args pure_impure_pair_overloads [ list_int; pure_cb ]
  with
  | Some entry ->
      check_true "picked pure overload (more specific)" (entry.ol_purity = Pure)
  | None -> Alcotest.fail "expected unique pure overload, got None"

let test_select_returns_none_on_first_arg_mismatch () =
  (* Wrong receiver type (Set instead of List): both overloads' first
     params have head "List", neither matches. *)
  let set_int = TyNamed ("Set", [ ty_int ]) in
  let impure_cb =
    TyFunc
      {
        params = [ ty_int ];
        return = TyNamed ("List", [ ty_int ]);
        is_pure = false;
      }
  in
  check_none "no match for non-List receiver"
    (select_overload_for_args pure_impure_pair_overloads [ set_int; impure_cb ])

let test_select_rejects_same_head_incompatible_args () =
  let stats_count =
    {
      ol_def_id = 0;
      ol_func_type =
        TyFunc
          {
            params = [ TyNamed ("List", [ ty_float ]) ];
            return = ty_int;
            is_pure = true;
          };
      ol_type_params = [];
      ol_param_names = [ Some "data" ];
      ol_purity = Pure;
      ol_origin = UserDefined;
      ol_resource_args = RejectResourceArgs;
      ol_dim_constraints = [];
      ol_module_path = Some "std/stats";
      ol_loop_producer = None;
      ol_debug_only = false;
    }
  in
  let string_count =
    {
      ol_def_id = 0;
      ol_func_type =
        TyFunc
          { params = [ ty_string; ty_string ]; return = ty_int; is_pure = true };
      ol_type_params = [];
      ol_param_names = [ Some "self"; Some "needle" ];
      ol_purity = Pure;
      ol_origin = UserDefined;
      ol_resource_args = RejectResourceArgs;
      ol_dim_constraints = [];
      ol_module_path = Some "std/string";
      ol_loop_producer = None;
      ol_debug_only = false;
    }
  in
  check_none "List[Int] must not pick stats.count(List[Float])"
    (select_overload_for_args
       [ stats_count; string_count ]
       [ TyNamed ("List", [ ty_int ]) ])

let test_is_local_func_distinguishes_imported_and_builtin () =
  let local_env =
    add_func (empty ()) "count"
      (TyFunc
         {
           params = [ TyNamed ("List", [ ty_int ]) ];
           return = ty_int;
           is_pure = false;
         })
      ()
  in
  check_true "local user function is local" (is_local_func local_env "count");
  let imported_env =
    add_func (empty ()) "count"
      (TyFunc
         {
           params = [ TyNamed ("List", [ ty_float ]) ];
           return = ty_int;
           is_pure = true;
         })
      ~module_path:"std/stats" ()
  in
  check_false "imported function is not local"
    (is_local_func imported_env "count");
  let builtin_env =
    add_func (empty ()) "length"
      (TyFunc { params = [ TyVar "T" ]; return = ty_int; is_pure = true })
      ~origin:Builtin ()
  in
  check_false "builtin function is not local"
    (is_local_func builtin_env "length")

(* ============================================================================
   Session-owned env tables — regression tests

   These guard against the class of bug that motivated moving session-wide
   env tables out of a module-level [Env.empty] binding and into the session:
   process-global state leaking across independent [Pipeline.compile] calls,
   producing order-dependent test failures. Ordinary overload sets are
   separately tested as env-local lexical state.
   ============================================================================ *)

let make_test_impl trait for_type =
  {
    ii_def_id = 0;
    ii_trait = trait;
    ii_for_type = for_type;
    ii_bounds = [];
    ii_is_builtin = false;
    ii_loc = None;
  }

let make_test_overload ~first_param_type =
  let ft =
    TyFunc { params = [ first_param_type ]; return = ty_int; is_pure = true }
  in
  {
    ol_def_id = 0;
    ol_func_type = ft;
    ol_type_params = [];
    ol_param_names = [ None ];
    ol_purity = Pure;
    ol_origin = UserDefined;
    ol_resource_args = RejectResourceArgs;
    ol_module_path = Some "test/mod";
    ol_dim_constraints = [];
    ol_loop_producer = None;
    ol_debug_only = false;
  }

(** Two independent [Session.t]'s must not share state. An impl
    registered in one must not appear in the other's [impl_index]. *)
let test_cross_session_impl_isolation () =
  let sess_a = Blorp.Session.create () in
  let sess_b = Blorp.Session.create () in
  Blorp.Session.with_current sess_a (fun () ->
      let env = add_impl (empty ()) (make_test_impl "TestTrait" ty_int) in
      check_true "impl visible in session A"
        (type_implements_trait env ty_int "TestTrait"));
  Blorp.Session.with_current sess_b (fun () ->
      check_false "impl NOT visible in session B"
        (type_implements_trait (empty ()) ty_int "TestTrait"))

(** Two independent sessions must not share overload state either. *)
let test_cross_session_overload_isolation () =
  let sess_a = Blorp.Session.create () in
  let sess_b = Blorp.Session.create () in
  Blorp.Session.with_current sess_a (fun () ->
      let env =
        add_overload (empty ()) "test_fn"
          (make_test_overload ~first_param_type:ty_int)
      in
      check_true "overload visible in session A"
        (List.length (get_overloads env "test_fn") = 1));
  Blorp.Session.with_current sess_b (fun () ->
      check_true "no overloads in session B"
        (List.length (get_overloads (empty ()) "test_fn") = 0))

(** Within a single session, impl additions to one env must be visible to a
    later env derived from the same session. This preserves the invariant that
    public impls registered while typechecking one module are available for
    trait dispatch in later modules from the same compile. *)
let test_within_session_impl_visibility () =
  let sess = Blorp.Session.create () in
  Blorp.Session.with_current sess (fun () ->
      (* First env — register impl *)
      let _env_a = add_impl (empty ()) (make_test_impl "TestTrait" ty_int) in
      (* Second env, same session — should see it *)
      let env_b = empty () in
      check_true "impl visible in new env from same session"
        (type_implements_trait env_b ty_int "TestTrait"))

(** Overload additions are different: they model lexical imports, so a later
    env in the same session must not inherit them. Otherwise one module's
    selective import can change another module's call resolution. *)
let test_within_session_overload_isolation () =
  let sess = Blorp.Session.create () in
  Blorp.Session.with_current sess (fun () ->
      let _env_a =
        add_overload (empty ()) "test_fn"
          (make_test_overload ~first_param_type:ty_int)
      in
      let env_b = empty () in
      check_true "overload NOT visible in new env from same session"
        (List.length (get_overloads env_b "test_fn") = 0))

(** [Env_builtins.with_builtins] registers builtin impls ([Integer
    for Int], etc.) into [session.impl_index]. The
    [sess.builtins_populated] guard must make repeat calls within one
    session skip impl registration (scope-symbol additions still
    happen per call). *)
let test_with_builtins_dedup_in_one_session () =
  let sess = Blorp.Session.create () in
  Blorp.Session.with_current sess (fun () ->
      let _env = Blorp.Env_builtins.with_builtins (empty ()) in
      let count_after_first =
        match Hashtbl.find_opt sess.impl_index "Integer" with
        | Some lst -> List.length lst
        | None -> 0
      in
      check_true "builtin impls registered on first call" (count_after_first > 0);
      (* Second call — scope symbols re-added, impls must NOT duplicate *)
      let _env' = Blorp.Env_builtins.with_builtins (empty ()) in
      let count_after_second =
        match Hashtbl.find_opt sess.impl_index "Integer" with
        | Some lst -> List.length lst
        | None -> 0
      in
      Alcotest.(check int)
        "impl count unchanged after second with_builtins" count_after_first
        count_after_second)

(** [Env.empty ()] must read from the ambient session, not from a
    captured reference. Entering a [with_current] frame and calling
    [empty ()] inside must return an env whose tables are that
    frame's tables. *)
let test_envempty_reads_ambient_session () =
  let outer = Blorp.Session.create () in
  let inner = Blorp.Session.create () in
  Blorp.Session.with_current outer (fun () ->
      let _ = add_impl (empty ()) (make_test_impl "OuterTrait" ty_int) in
      Blorp.Session.with_current inner (fun () ->
          (* Inside the inner frame, empty () reads inner's tables *)
          check_false "outer trait NOT visible inside inner"
            (type_implements_trait (empty ()) ty_int "OuterTrait"));
      (* Back in outer — visibility restored *)
      check_true "outer trait visible after inner pops"
        (type_implements_trait (empty ()) ty_int "OuterTrait"))

let suite =
  [
    ("empty env", [ Alcotest.test_case "empty" `Quick test_empty_env ]);
    ( "variables",
      [
        Alcotest.test_case "add and lookup" `Quick test_add_and_lookup_var;
        Alcotest.test_case "refinement metadata" `Quick
          test_add_var_preserves_refinement_metadata;
        Alcotest.test_case "set refinement metadata" `Quick
          test_set_var_refinement_updates_nearest_binding;
        Alcotest.test_case "set refinement rejects non-variable" `Quick
          test_set_var_refinement_rejects_non_variable;
        Alcotest.test_case "shadowing" `Quick test_scope_shadowing;
        Alcotest.test_case "current scope" `Quick test_lookup_in_current_scope;
        Alcotest.test_case "scope traversal" `Quick test_lookup_traverses_scopes;
      ] );
    ( "functions",
      [
        Alcotest.test_case "add and lookup" `Quick test_add_and_lookup_func;
        Alcotest.test_case "builtin detection" `Quick test_is_builtin_func;
        Alcotest.test_case "loop producer metadata" `Quick
          test_loop_producer_metadata;
        Alcotest.test_case "builtin resource args opt in" `Quick
          test_builtin_resource_args_require_explicit_opt_in;
      ] );
    ( "function context",
      [ Alcotest.test_case "enter function" `Quick test_enter_function ] );
    ( "union types",
      [
        Alcotest.test_case "add type" `Quick test_add_union_type;
        Alcotest.test_case "constructor info" `Quick test_constructor_info;
        Alcotest.test_case "type kind preserved" `Quick test_type_kind_preserved;
      ] );
    ( "records",
      [
        Alcotest.test_case "add record" `Quick test_add_record;
        Alcotest.test_case "struct (value type)" `Quick test_add_struct;
      ] );
    ( "aliases",
      [
        Alcotest.test_case "basic alias" `Quick test_add_and_resolve_alias;
        Alcotest.test_case "recursive alias" `Quick test_resolve_alias_recursive;
        Alcotest.test_case "cycle detection" `Quick test_resolve_alias_cycle;
        Alcotest.test_case "parameterized alias" `Quick
          test_resolve_alias_with_params;
        Alcotest.test_case "alias in type arguments" `Quick
          test_resolve_alias_in_type_arguments;
        Alcotest.test_case "alias in array element" `Quick
          test_resolve_alias_in_array_element;
        Alcotest.test_case "dimension-only alias application" `Quick
          test_disambiguate_nominal_dim_application;
      ] );
    ( "direct_subst",
      [ Alcotest.test_case "substitution" `Quick test_direct_subst ] );
    ( "traits",
      [
        Alcotest.test_case "trait functions" `Quick test_trait_functions;
        Alcotest.test_case "param bounds structured" `Quick
          test_type_param_bounds_from_structured_params;
        Alcotest.test_case "param bounds" `Quick test_type_param_bounds;
        Alcotest.test_case "trait obligation satisfaction" `Quick
          test_trait_obligation_satisfaction;
        Alcotest.test_case "trait obligation declared type names" `Quick
          test_trait_obligation_respects_declared_type_names;
        Alcotest.test_case "trait obligation generation" `Quick
          test_trait_obligations_for_bound_type_param;
        Alcotest.test_case "trait obligation resolution states" `Quick
          test_resolve_trait_obligation_states;
        Alcotest.test_case "trait obligation named type param" `Quick
          test_trait_obligation_satisfies_named_type_param;
        Alcotest.test_case "trait obligation structured bound var" `Quick
          test_trait_obligation_structured_bound_var_is_not_deferred;
        Alcotest.test_case "trait obligation impl and supertrait resolution"
          `Quick test_resolve_trait_obligation_from_impl_and_supertrait_bound;
        Alcotest.test_case "trait obligation first unsatisfied" `Quick
          test_find_unsatisfied_trait_obligation;
        Alcotest.test_case "trait registration" `Quick test_trait_registration;
        Alcotest.test_case "session fallback" `Quick
          test_get_trait_falls_back_to_session;
        Alcotest.test_case "env wins over session" `Quick
          test_env_traits_win_over_session_fallback;
        Alcotest.test_case "structurally equal identical" `Quick
          test_structurally_equal_identical;
        Alcotest.test_case "structurally equal ignores loc" `Quick
          test_structurally_equal_ignores_location;
        Alcotest.test_case "structurally unequal supertraits" `Quick
          test_structurally_unequal_supertraits;
        Alcotest.test_case "structurally unequal methods" `Quick
          test_structurally_unequal_methods;
        Alcotest.test_case "try_add_trait idempotent" `Quick
          test_try_add_trait_idempotent;
        Alcotest.test_case "try_add_trait stub replaced" `Quick
          test_try_add_trait_stub_replaced_by_decl;
        Alcotest.test_case "try_add_trait conflict" `Quick
          test_try_add_trait_conflict;
        Alcotest.test_case "method names: own" `Quick
          test_trait_method_names_no_supertraits;
        Alcotest.test_case "method names: with supertraits" `Quick
          test_trait_method_names_walks_supertraits;
        Alcotest.test_case "method names: cycle-safe" `Quick
          test_trait_method_names_handles_cycle;
        Alcotest.test_case "method names: missing trait" `Quick
          test_trait_method_names_missing_trait;
        Alcotest.test_case "impl instance" `Quick test_impl_instance;
        Alcotest.test_case "generic impl" `Quick test_generic_impl;
        Alcotest.test_case "resolve Self" `Quick test_resolve_self;
      ] );
    ( "levenshtein",
      [
        Alcotest.test_case "distance" `Quick test_levenshtein;
        Alcotest.test_case "find similar" `Quick test_find_similar;
      ] );
    ( "format_trait_name",
      [
        Alcotest.test_case "trait with module renders qualified" `Quick
          test_format_trait_name_with_module;
        Alcotest.test_case "builtin trait renders bare" `Quick
          test_format_trait_name_builtin_unqualified;
        Alcotest.test_case "unknown trait renders bare" `Quick
          test_format_trait_name_unknown;
      ] );
    ( "format_overload_ref",
      [
        Alcotest.test_case "overload with module renders qualified" `Quick
          test_format_overload_ref_with_module;
        Alcotest.test_case "overload without module renders bare" `Quick
          test_format_overload_ref_bare;
      ] );
    ( "def_id",
      [
        Alcotest.test_case "ids unique within session" `Quick
          test_def_id_mint_unique_within_session;
        Alcotest.test_case "per-session isolation" `Quick
          test_def_id_per_session_isolation;
        Alcotest.test_case "overload entry carries def_id" `Quick
          test_overload_entry_carries_def_id;
      ] );
    ( "trait_function_collision",
      [
        Alcotest.test_case "unrelated traits same method collide" `Quick
          test_trait_function_collision_detected;
        Alcotest.test_case "same (method, trait) pair no collision" `Quick
          test_trait_function_no_collision_same_pair;
        Alcotest.test_case "different methods same trait no collision" `Quick
          test_trait_function_no_collision_different_method;
        Alcotest.test_case "supertrait sweep idempotent" `Quick
          test_trait_function_supertrait_idempotent;
      ] );
    ( "ufcs_collision",
      [
        Alcotest.test_case "cross-module same-type collision detected" `Quick
          test_ufcs_collision_cross_module_same_type;
        Alcotest.test_case "different receiver types no collision" `Quick
          test_ufcs_no_collision_different_types;
        Alcotest.test_case "same module re-registration no collision" `Quick
          test_ufcs_no_collision_same_module;
        Alcotest.test_case "pure/impure pair same module no collision" `Quick
          test_ufcs_no_collision_pure_impure_same_module;
        Alcotest.test_case "different purity across modules no collision" `Quick
          test_ufcs_no_collision_different_purity;
      ] );
    ( "ufcs_methods",
      [
        Alcotest.test_case "add and lookup" `Quick
          test_ufcs_method_add_and_lookup;
        Alcotest.test_case "multiple types" `Quick
          test_ufcs_method_multiple_types;
        Alcotest.test_case "pure/impure overloads" `Quick
          test_ufcs_method_pure_impure_overloads;
      ] );
    ( "purity_tiebreak",
      [
        Alcotest.test_case "impure cb selects impure overload" `Quick
          test_select_picks_impure_for_impure_cb;
        Alcotest.test_case "pure cb prefers pure overload" `Quick
          test_select_picks_pure_for_pure_cb;
        Alcotest.test_case "first-arg type mismatch returns None" `Quick
          test_select_returns_none_on_first_arg_mismatch;
        Alcotest.test_case "same-head incompatible args rejected" `Quick
          test_select_rejects_same_head_incompatible_args;
        Alcotest.test_case "local func provenance" `Quick
          test_is_local_func_distinguishes_imported_and_builtin;
      ] );
    ( "session_isolation",
      [
        Alcotest.test_case "cross-session impl isolation" `Quick
          test_cross_session_impl_isolation;
        Alcotest.test_case "cross-session overload isolation" `Quick
          test_cross_session_overload_isolation;
        Alcotest.test_case "within-session impl visibility" `Quick
          test_within_session_impl_visibility;
        Alcotest.test_case "within-session overload isolation" `Quick
          test_within_session_overload_isolation;
        Alcotest.test_case "Env.empty reads ambient session" `Quick
          test_envempty_reads_ambient_session;
        Alcotest.test_case "with_builtins dedup guard" `Quick
          test_with_builtins_dedup_in_one_session;
      ] );
  ]
