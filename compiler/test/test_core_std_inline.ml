(** Tests for narrow std-function call-site expansion.

    This pass is intentionally not a general function inliner. It only expands
    compiler-owned std functions whose synthesized Core bodies are part of the
    collection representation contract. *)

open Blorp.Ast
open Blorp.Core

let ty_int = TyNamed ("Int", [])
let ty_void = TyNamed ("Void", [])
let ty_list elem = TyNamed ("List", [ elem ])
let ty_option elem = TyNamed ("Option", [ elem ])
let mk ty desc = { desc; ty; loc = dummy_loc }
let void () = mk ty_void CVoid
let int n = mk ty_int (CLit (LitInt (Int64.of_int n)))
let var name ty = mk ty (CVar (Var.named name))
let none ty = mk (ty_option ty) (CVar (Var.named "None"))
let param name ty = { cp_name = Var.named name; cp_ty = ty; cp_loc = dummy_loc }

let user_call ?(def_id = None) name args ty =
  mk ty (CCall (CKUser (name, def_id), void (), args))

let bin op a b = mk ty_int (CBin (op, a, b))
let seq a b = mk b.ty (CSeq (a, b))

let resource_scope name ty acquire body cleanup =
  mk body.ty
    (CResourceScope
       {
         rs_var = Var.named name;
         rs_ty = ty;
         rs_acquire = acquire;
         rs_body = body;
         rs_cleanup = cleanup;
       })

let lett name rhs body =
  mk body.ty
    (CLet
       ( {
           bind_var = Var.named name;
           bind_mut = false;
           bind_ty = rhs.ty;
           bind_rhs = rhs;
         },
         body ))

let func ?(module_path = None) ?(kind = CFUser) ?body ?(params = [])
    ?(return_ty = ty_int) ~name ~def_id () =
  {
    cf_name = name;
    cf_module = module_path;
    cf_type_params = [];
    cf_params = params;
    cf_return_ty = return_ty;
    cf_body = body;
    cf_is_pure = true;
    cf_kind = kind;
    cf_def_id = def_id;
  }

let decl_func f = { cd_desc = CDFunc f; cd_loc = dummy_loc; cd_doc = None }

let target_get_or ?body () =
  let self = param "self" (ty_list ty_int) in
  let index = param "index" ty_int in
  let default = param "default" ty_int in
  let body = Option.value body ~default:(var "default" ty_int) in
  func ~module_path:(Some "std/list") ~name:"std_list__get_or__mono_Int"
    ~def_id:10 ~params:[ self; index; default ] ~body ~return_ty:ty_int ()

let target_get ?body () =
  let self = param "self" (ty_list ty_int) in
  let index = param "index" ty_int in
  let return_ty = ty_option ty_int in
  let body = Option.value body ~default:(none ty_int) in
  func ~module_path:(Some "std/list") ~name:"std_list__get__mono_Int" ~def_id:14
    ~params:[ self; index ] ~body ~return_ty ()

let target_append () =
  let self = param "self" (ty_list ty_int) in
  let elem = param "elem" ty_int in
  func ~module_path:(Some "std/list") ~name:"std_list__append__mono_Int"
    ~def_id:12 ~params:[ self; elem ]
    ~body:(var "self" (ty_list ty_int))
    ~return_ty:(ty_list ty_int) ()

let caller body =
  func ~name:"use_it" ~def_id:20 ~params:[] ~body ~return_ty:body.ty ()

let rewritten_body prog =
  let rewritten = Blorp.Core_std_inline.rewrite_program prog in
  match List.rev rewritten with
  | { cd_desc = CDFunc { cf_body = Some body; _ }; _ } :: _ -> body
  | _ -> Alcotest.fail "expected final function body"

let count_target_calls body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKUser (_, Some 10), _, _) -> acc + 1
      | _ -> acc)
    0 body

let count_user_calls_by_def_id def_id body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKUser (_, Some id), _, _) when id = def_id -> acc + 1
      | _ -> acc)
    0 body

let target_std_list_user_call = function
  | "std_list__get__mono_Int" | "std_list__get_or__mono_Int" -> true
  | _ -> false

let append_std_list_user_call = function
  | "std_list__append__mono_Int" -> true
  | _ -> false

let opaque_cow_transfer_std_list_user_call = function
  | "std_list__set__mono_Int" -> true
  | _ -> false

let count_std_list_user_calls body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKUser (name, _), _, _) when target_std_list_user_call name ->
          acc + 1
      | _ -> acc)
    0 body

let count_append_user_calls body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKUser (name, _), _, _) when append_std_list_user_call name ->
          acc + 1
      | _ -> acc)
    0 body

let count_opaque_cow_transfer_user_calls body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKUser (name, _), _, _)
        when opaque_cow_transfer_std_list_user_call name ->
          acc + 1
      | _ -> acc)
    0 body

let count_list_intrinsics body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKIntrinsic name, _, _)
        when String.starts_with ~prefix:"list_" name ->
          acc + 1
      | _ -> acc)
    0 body

let count_side_effect_calls body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKUser ("side_effect", _), _, _) -> acc + 1
      | _ -> acc)
    0 body

let let_c_names body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CLet (binding, _) -> Var.to_c_name binding.bind_var :: acc
      | _ -> acc)
    [] body

let borrow_c_names body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CBorrowLet (binding, _) -> Var.to_c_name binding.borrow_var :: acc
      | _ -> acc)
    [] body

let find_func_body name prog =
  let rec find_decl = function
    | { cd_desc = CDFunc { cf_name; cf_body = Some body; _ }; _ }
      when cf_name = name ->
        Some body
    | { cd_desc = CDPrivate inner; _ } -> find_decl inner
    | _ -> None
  in
  List.find_map find_decl prog

let test_inlines_allowed_std_list_target () =
  let call =
    user_call ~def_id:(Some 10) "std_list__get_or__mono_Int"
      [ var "xs" (ty_list ty_int); int 0; int 99 ]
      ty_int
  in
  let body =
    rewritten_body [ decl_func (target_get_or ()); decl_func (caller call) ]
  in
  Alcotest.(check int) "target calls removed" 0 (count_target_calls body);
  Alcotest.(check bool)
    "existing variable argument is borrowed before cloned body" true
    (List.exists
       (fun name -> String.starts_with ~prefix:"__std_inline_self" name)
       (borrow_c_names body))

let test_inlines_allowed_std_list_get_target () =
  let return_ty = ty_option ty_int in
  let call =
    user_call ~def_id:(Some 14) "std_list__get__mono_Int"
      [ var "xs" (ty_list ty_int); int 0 ]
      return_ty
  in
  let body =
    rewritten_body [ decl_func (target_get ()); decl_func (caller call) ]
  in
  Alcotest.(check int)
    "get wrapper call is removed" 0
    (count_user_calls_by_def_id 14 body);
  Alcotest.(check bool)
    "existing list argument is borrowed before cloned body" true
    (List.exists
       (fun name -> String.starts_with ~prefix:"__std_inline_self" name)
       (borrow_c_names body))

let test_preserves_argument_single_evaluation () =
  let side_effect = user_call "side_effect" [] ty_int in
  let target_body = bin Add (var "default" ty_int) (var "default" ty_int) in
  let call =
    user_call ~def_id:(Some 10) "std_list__get_or__mono_Int"
      [ var "xs" (ty_list ty_int); int 0; side_effect ]
      ty_int
  in
  let body =
    rewritten_body
      [
        decl_func (target_get_or ~body:target_body ()); decl_func (caller call);
      ]
  in
  Alcotest.(check int)
    "side-effecting argument evaluated once" 1
    (count_side_effect_calls body);
  Alcotest.(check bool)
    "non-variable argument uses owned binding for lifetime" true
    (List.exists
       (fun name -> String.starts_with ~prefix:"__std_inline_default" name)
       (let_c_names body))

let test_alpha_renames_cloned_locals () =
  let target_body = lett "__tmp" (var "default" ty_int) (var "__tmp" ty_int) in
  let call n =
    user_call ~def_id:(Some 10) "std_list__get_or__mono_Int"
      [ var "xs" (ty_list ty_int); int n; int n ]
      ty_int
  in
  let body =
    rewritten_body
      [
        decl_func (target_get_or ~body:target_body ());
        decl_func (caller (seq (call 0) (call 1)));
      ]
  in
  let names = let_c_names body in
  let sorted = List.sort String.compare names in
  let rec has_duplicate = function
    | a :: b :: _ when a = b -> true
    | _ :: rest -> has_duplicate rest
    | [] -> false
  in
  Alcotest.(check bool)
    "cloned C let names are unique" false (has_duplicate sorted)

let test_does_not_inline_inside_std_list_module () =
  let wrapper_body =
    user_call ~def_id:(Some 10) "std_list__get_or__mono_Int"
      [ var "xs" (ty_list ty_int); int 0; int 99 ]
      ty_int
  in
  let wrapper =
    func ~module_path:(Some "std/list") ~name:"std_list__wrapper__mono_Int"
      ~def_id:11
      ~params:[ param "xs" (ty_list ty_int) ]
      ~body:wrapper_body ~return_ty:ty_int ()
  in
  let rewritten =
    Blorp.Core_std_inline.rewrite_program
      [ decl_func (target_get_or ()); decl_func wrapper ]
  in
  match find_func_body "std_list__wrapper__mono_Int" rewritten with
  | Some body ->
      Alcotest.(check int)
        "std/list implementation bodies keep helper calls" 1
        (count_target_calls body)
  | None -> Alcotest.fail "expected std/list wrapper body"

let test_inlines_append_with_substituted_variable_receiver () =
  let call =
    user_call ~def_id:(Some 12) "std_list__append__mono_Int"
      [ var "xs" (ty_list ty_int); int 4 ]
      (ty_list ty_int)
  in
  let body =
    rewritten_body [ decl_func (target_append ()); decl_func (caller call) ]
  in
  Alcotest.(check int)
    "append wrapper call is removed" 0
    (count_user_calls_by_def_id 12 body);
  Alcotest.(check bool)
    "append variable receiver is substituted directly, not rebound" false
    (List.exists
       (fun name -> String.starts_with ~prefix:"__std_inline_self" name)
       (let_c_names body));
  Alcotest.(check bool)
    "append receiver is not borrowed before cloned body" false
    (List.exists
       (fun name -> String.starts_with ~prefix:"__std_inline_self" name)
       (borrow_c_names body))

let test_clones_resource_scope_binding_hygienically () =
  let target_body =
    resource_scope "default" ty_int (var "default" ty_int)
      (var "default" ty_int) (var "default" ty_int)
  in
  let call =
    user_call ~def_id:(Some 10) "std_list__get_or__mono_Int"
      [ var "xs" (ty_list ty_int); int 0; int 99 ]
      ty_int
  in
  let body =
    rewritten_body
      [
        decl_func (target_get_or ~body:target_body ()); decl_func (caller call);
      ]
  in
  match body.desc with
  | CBorrowLet
      ( _,
        {
          desc =
            CLet
              ( _,
                {
                  desc =
                    CLet
                      ( default_binding,
                        {
                          desc =
                            CResourceScope
                              {
                                rs_var;
                                rs_acquire = { desc = CVar acquire; _ };
                                rs_body = { desc = CVar body_var; _ };
                                rs_cleanup = { desc = CVar cleanup_var; _ };
                                _;
                              };
                          _;
                        } );
                  _;
                } );
          _;
        } ) ->
      Alcotest.(check bool) "scope binder is fresh" true (rs_var.vuniq <> 0);
      Alcotest.(check bool)
        "acquire reads cloned argument binding" true
        (Var.equal acquire default_binding.bind_var);
      Alcotest.(check bool)
        "body reads scoped binding" true
        (Var.equal body_var rs_var);
      Alcotest.(check bool)
        "cleanup reads scoped binding" true
        (Var.equal cleanup_var rs_var);
      Alcotest.(check bool)
        "body does not read argument binding" false
        (Var.equal body_var default_binding.bind_var)
  | _ ->
      Alcotest.failf "unexpected inlined shape:\n%s"
        (Blorp.Core.pp_to_string body)

let test_pipeline_expands_real_std_list_calls () =
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  let source =
    {|
import:
    list: get_or, set, append

pure func touch(xs: List[Int]) -> Int:
    ys: List[Int] = xs.set(0, xs.get_or(0, 0) + 1)
    zs: List[Int] = ys.append(2)
    zs.get_or(0, 0)

func main(args: List[String]) -> Int:
    touch([1, 2, 3])
|}
  in
  let resolved_calls = ref None in
  let inlined_calls = ref None in
  let inlined_intrinsics = ref None in
  let append_calls = ref None in
  let opaque_cow_transfer_calls = ref None in
  let on_stage stage program =
    match (stage, find_func_body "touch" program) with
    | Blorp.Core_stage.Resolve, Some body ->
        resolved_calls := Some (count_std_list_user_calls body)
    | Blorp.Core_stage.StdInline, Some body ->
        inlined_calls := Some (count_std_list_user_calls body);
        inlined_intrinsics := Some (count_list_intrinsics body);
        append_calls := Some (count_append_user_calls body);
        opaque_cow_transfer_calls :=
          Some (count_opaque_cow_transfer_user_calls body)
    | _ -> ()
  in
  match
    Blorp.Pipeline.compile ~embed_runtime:false ~on_stage ~filename:"<test>"
      ~source ()
  with
  | Ok (Blorp.Pipeline.Compiled _) ->
      Alcotest.(check bool)
        "resolve stage still has std/list calls" true
        (Option.value ~default:0 !resolved_calls > 0);
      Alcotest.(check int)
        "std_inline removes std/list calls from caller" 0
        (Option.value ~default:(-1) !inlined_calls);
      Alcotest.(check bool)
        "std_inline exposes list intrinsics" true
        (Option.value ~default:0 !inlined_intrinsics > 0);
      Alcotest.(check int)
        "std_inline removes append wrappers from caller" 0
        (Option.value ~default:(-1) !append_calls);
      Alcotest.(check bool)
        "std_inline still leaves other COW transfer wrappers opaque" true
        (Option.value ~default:0 !opaque_cow_transfer_calls > 0)
  | Ok (Blorp.Pipeline.Stopped_at s) ->
      Alcotest.failf "unexpected stop at %s" (Blorp.Core_stage.to_string s)
  | Error errs -> Alcotest.failf "compile failed: %d errors" (List.length errs)

let suite =
  [
    ( "rewrite",
      [
        Alcotest.test_case "inlines_allowed_std_list_target" `Quick
          test_inlines_allowed_std_list_target;
        Alcotest.test_case "inlines_allowed_std_list_get_target" `Quick
          test_inlines_allowed_std_list_get_target;
        Alcotest.test_case "preserves_argument_single_evaluation" `Quick
          test_preserves_argument_single_evaluation;
        Alcotest.test_case "alpha_renames_cloned_locals" `Quick
          test_alpha_renames_cloned_locals;
        Alcotest.test_case "does_not_inline_inside_std_list_module" `Quick
          test_does_not_inline_inside_std_list_module;
        Alcotest.test_case "inlines_append_with_substituted_variable_receiver"
          `Quick test_inlines_append_with_substituted_variable_receiver;
        Alcotest.test_case "clones_resource_scope_binding_hygienically" `Quick
          test_clones_resource_scope_binding_hygienically;
        Alcotest.test_case "pipeline_expands_real_std_list_calls" `Quick
          test_pipeline_expands_real_std_list_calls;
      ] );
  ]
