(** Tests for Core_resolve: post-lowering [CCall] tagging.

    The resolver walks a [core_program] and rewrites every
    [CCall (CKUnknown, ...)] to a concrete [call_kind] when the
    callee name can be looked up in the program.

    Tests cover:
    - User-defined functions in the program → [CKUser].
    - Foreign functions → [CKForeign] with the C name.
    - Unknown callees → [CKUnknown] (left as-is).
    - Rewriting happens recursively (nested calls get resolved). *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_void = TyNamed ("Void", [])
let str_flags = { sf_triple = false; sf_raw = false }
let tparams names = List.map (fun name -> make_type_param name []) names
let mk d t = { desc = d; ty = t; loc }
let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int
let cstr s = mk (CLit (LitString (s, str_flags))) (TyNamed ("String", []))
let cvar n t = mk (CVar (Var.named n)) t

(** Convenience: wrap a call with CKUnknown (matches lowering output). *)
let mk_call fn_name fn_ty args ret_ty =
  let callee = cvar fn_name fn_ty in
  mk (CCall (CKUnknown, callee, args)) ret_ty

(** Build a core program containing one function with the given body. *)
let program_with_func ?(foreign_name = None) name params ret_ty body =
  let func : core_func =
    {
      cf_name = name;
      cf_module = None;
      cf_type_params = [];
      cf_params =
        List.map
          (fun (n, t) -> { cp_name = Var.named n; cp_ty = t; cp_loc = loc })
          params;
      cf_return_ty = ret_ty;
      cf_body = body;
      cf_is_pure = false;
      cf_kind =
        (match foreign_name with
        | Some c_name ->
            CFForeign
              {
                c_name;
                includes = [];
                link_flags = [];
                arg_passing = ForeignDefaultArgs [];
              }
        | None -> CFUser);
      cf_def_id = 0;
    }
  in
  let decl = { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } in
  [ decl ]

let get_func_body (prog : core_program) : core =
  match prog with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
  | _ -> Alcotest.fail "expected single CDFunc with body"

let expect_builtin_call label expected body =
  match body.desc with
  | CCall (CKBuiltin c_name, _, _) ->
      Alcotest.(check string) label expected c_name
  | CCall (CKClosure, _, _) ->
      Alcotest.failf "%s resolved as CKClosure, expected CKBuiltin %s" label
        expected
  | CCall (CKUnknown, _, _) ->
      Alcotest.failf "%s stayed CKUnknown, expected CKBuiltin %s" label expected
  | CCall (kind, _, _) ->
      let got =
        match kind with
        | CKUser (n, _) -> "CKUser " ^ n
        | CKForeign { fc_c_name; _ } -> "CKForeign " ^ fc_c_name
        | CKIntrinsic n -> "CKIntrinsic " ^ n
        | CKBuiltin n -> "CKBuiltin " ^ n
        | CKClosure -> "CKClosure"
        | CKUnknown -> "CKUnknown"
        | CKSelectedDirect id -> Printf.sprintf "CKSelectedDirect %d" id
      in
      Alcotest.failf "%s resolved as %s, expected CKBuiltin %s" label got
        expected
  | _ -> Alcotest.failf "%s expected CCall" label

let expect_intrinsic_call label expected body =
  match body.desc with
  | CCall (CKIntrinsic name, _, _) ->
      Alcotest.(check string) label expected name
  | CCall (CKClosure, _, _) ->
      Alcotest.failf "%s resolved as CKClosure, expected CKIntrinsic %s" label
        expected
  | CCall (CKUnknown, _, _) ->
      Alcotest.failf "%s stayed CKUnknown, expected CKIntrinsic %s" label
        expected
  | CCall (kind, _, _) ->
      let got =
        match kind with
        | CKUser (n, _) -> "CKUser " ^ n
        | CKForeign { fc_c_name; _ } -> "CKForeign " ^ fc_c_name
        | CKIntrinsic n -> "CKIntrinsic " ^ n
        | CKBuiltin n -> "CKBuiltin " ^ n
        | CKClosure -> "CKClosure"
        | CKUnknown -> "CKUnknown"
        | CKSelectedDirect id -> Printf.sprintf "CKSelectedDirect %d" id
      in
      Alcotest.failf "%s resolved as %s, expected CKIntrinsic %s" label got
        expected
  | _ -> Alcotest.failf "%s expected CCall" label

(* ============================================================================
   Env collection
   ============================================================================ *)

let test_collect_empty () =
  let env =
    Blorp.Core_resolve.collect_env ~import_aliases:(Hashtbl.create 0)
      ~module_imports:(Hashtbl.create 0) []
  in
  Alcotest.(check int) "no user funcs" 0 (Hashtbl.length env.user_funcs);
  Alcotest.(check int) "no foreign funcs" 0 (Hashtbl.length env.foreign_funcs)

let test_collect_user_func () =
  let prog =
    program_with_func "inc" [ ("x", ty_int) ] ty_int (Some (cint 42))
  in
  let env =
    Blorp.Core_resolve.collect_env ~import_aliases:(Hashtbl.create 0)
      ~module_imports:(Hashtbl.create 0) prog
  in
  Alcotest.(check bool)
    "user func present" true
    (Hashtbl.mem env.user_funcs "inc");
  Alcotest.(check bool)
    "not foreign" true
    (not (Hashtbl.mem env.foreign_funcs "inc"))

let test_collect_user_func_indexes_name_by_def_id () =
  let func : core_func =
    {
      cf_name = "apply__pure";
      cf_module = None;
      cf_type_params = [];
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (cint 42);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 42;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let env =
    Blorp.Core_resolve.collect_env ~import_aliases:(Hashtbl.create 0)
      ~module_imports:(Hashtbl.create 0) prog
  in
  Alcotest.(check (option string))
    "name by def id" (Some "apply__pure")
    (Hashtbl.find_opt env.user_func_names_by_id 42)

let test_collect_duplicate_def_id_marks_id_ambiguous () =
  let make_func name : core_func =
    {
      cf_name = name;
      cf_module = None;
      cf_type_params = [];
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (cint 42);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc (make_func "inc"); cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc (make_func "main"); cd_loc = loc; cd_doc = None };
    ]
  in
  let env =
    Blorp.Core_resolve.collect_env ~import_aliases:(Hashtbl.create 0)
      ~module_imports:(Hashtbl.create 0) prog
  in
  Alcotest.(check (option string))
    "ambiguous id removed from reverse index" None
    (Hashtbl.find_opt env.user_func_names_by_id 0);
  Alcotest.(check bool)
    "duplicate id tracked as ambiguous" true
    (Hashtbl.mem env.ambiguous_user_func_ids 0)

let test_collect_foreign_func () =
  let prog =
    program_with_func ~foreign_name:(Some "c_printf") "printf"
      [ ("fmt", TyNamed ("String", [])) ]
      ty_void None
  in
  let env =
    Blorp.Core_resolve.collect_env ~import_aliases:(Hashtbl.create 0)
      ~module_imports:(Hashtbl.create 0) prog
  in
  Alcotest.(check bool)
    "foreign present" true
    (Hashtbl.mem env.foreign_funcs "printf");
  let foreign = Hashtbl.find_opt env.foreign_funcs "printf" in
  Alcotest.(check (option string))
    "foreign c_name" (Some "c_printf")
    (Option.map (fun f -> f.fc_c_name) foreign);
  Alcotest.(check (option bool))
    "foreign arg passing" (Some true)
    (Option.map (fun f -> f.fc_arg_passing = ForeignDefaultArgs []) foreign);
  Alcotest.(check bool)
    "not user" true
    (not (Hashtbl.mem env.user_funcs "printf"))

(* ============================================================================
   Call resolution
   ============================================================================ *)

let test_resolve_user_call () =
  (* func inc(x: Int) -> Int: 42
     func main() -> Int: inc(10) — the inc call should become CKUser *)
  let inc_func : core_func =
    {
      cf_name = "inc";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (cint 42);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let inc_fty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let main_body = mk_call "inc" inc_fty [ cint 10 ] ty_int in
  let main_func : core_func =
    {
      cf_name = "main";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some main_body;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc inc_func; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main_func; cd_loc = loc; cd_doc = None };
    ]
  in
  let resolved = Blorp.Core_resolve.resolve_program prog in
  (* Extract main's body and check the call got tagged. *)
  let main_resolved =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected two funcs"
  in
  match main_resolved.desc with
  | CCall (CKUser ("inc", _), _, _) -> ()
  | CCall (k, _, _) ->
      Alcotest.failf "expected CKUser, got %s"
        (match k with
        | CKUnknown -> "CKUnknown"
        | CKUser (n, _) -> "CKUser " ^ n
        | CKForeign { fc_c_name; _ } -> "CKForeign " ^ fc_c_name
        | CKBuiltin n -> "CKBuiltin " ^ n
        | CKIntrinsic n -> "CKIntrinsic " ^ n
        | CKClosure -> "CKClosure"
        | CKSelectedDirect id -> Printf.sprintf "CKSelectedDirect %d" id)
  | _ -> Alcotest.fail "expected CCall at root"

let test_resolve_user_call_prefers_carried_def_id_name () =
  let pure_func : core_func =
    {
      cf_name = "apply__pure";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (cint 42);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 42;
    }
  in
  let call_ty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let selected =
    mk
      (CVar { (Var.named "apply") with vdef_id = Some pure_func.cf_def_id })
      call_ty
  in
  let call = mk (CCall (CKUnknown, selected, [ cint 1 ])) ty_int in
  let main_f : core_func =
    {
      cf_name = "main";
      cf_type_params = [];
      cf_module = None;
      cf_params = [];
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc pure_func; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main_f; cd_loc = loc; cd_doc = None };
    ]
  in
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases:(Hashtbl.create 0)
      ~module_imports:(Hashtbl.create 0) prog
  in
  let main_resolved =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected selected call in main"
  in
  match main_resolved.desc with
  | CCall (CKUser (name, def_id), _, _) ->
      Alcotest.(check string) "canonical selected name" "apply__pure" name;
      Alcotest.(check (option int)) "selected def id" (Some 42) def_id
  | _ -> Alcotest.fail "expected CKUser selected by carried def id"

let test_resolve_user_call_prefers_selected_direct_kind () =
  let pure_func : core_func =
    {
      cf_name = "apply__pure";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (cint 42);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 43;
    }
  in
  let call_ty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let selected = mk (CVar (Var.named "apply")) call_ty in
  let call =
    mk
      (CCall (CKSelectedDirect pure_func.cf_def_id, selected, [ cint 1 ]))
      ty_int
  in
  let main_f : core_func =
    {
      cf_name = "main";
      cf_type_params = [];
      cf_module = None;
      cf_params = [];
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc pure_func; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main_f; cd_loc = loc; cd_doc = None };
    ]
  in
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases:(Hashtbl.create 0)
      ~module_imports:(Hashtbl.create 0) prog
  in
  let main_resolved =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected selected call in main"
  in
  match main_resolved.desc with
  | CCall (CKUser (name, def_id), _, _) ->
      Alcotest.(check string) "canonical selected name" "apply__pure" name;
      Alcotest.(check (option int)) "selected def id" (Some 43) def_id
  | _ -> Alcotest.fail "expected CKUser selected by call kind def id"

let test_resolve_bitwise_calls_to_intrinsics () =
  let bitwise_ty =
    TyFunc { params = [ ty_int; ty_int ]; return = ty_int; is_pure = true }
  in
  let bit_not_ty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let cases =
    [
      ("bit_and", bitwise_ty, [ cint 1; cint 2 ]);
      ("bit_or", bitwise_ty, [ cint 1; cint 2 ]);
      ("bit_xor", bitwise_ty, [ cint 1; cint 2 ]);
      ("bit_not", bit_not_ty, [ cint 1 ]);
      ("shift_left", bitwise_ty, [ cint 1; cint 2 ]);
      ("shift_right", bitwise_ty, [ cint 1; cint 2 ]);
    ]
  in
  List.iter
    (fun (name, fn_ty, args) ->
      let body = mk_call name fn_ty args ty_int in
      let prog = program_with_func "main" [] ty_int (Some body) in
      let resolved = Blorp.Core_resolve.resolve_program prog in
      let body = get_func_body resolved in
      expect_intrinsic_call name name body)
    cases

let test_resolve_user_bitwise_name_before_intrinsic () =
  let fn_ty =
    TyFunc { params = [ ty_int; ty_int ]; return = ty_int; is_pure = true }
  in
  let user_func : core_func =
    {
      cf_name = "bit_and";
      cf_type_params = [];
      cf_module = None;
      cf_params =
        [
          { cp_name = Var.named "left"; cp_ty = ty_int; cp_loc = loc };
          { cp_name = Var.named "right"; cp_ty = ty_int; cp_loc = loc };
        ];
      cf_return_ty = ty_int;
      cf_body = Some (cint 42);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 91;
    }
  in
  let main_func : core_func =
    {
      cf_name = "main";
      cf_type_params = [];
      cf_module = None;
      cf_params = [];
      cf_return_ty = ty_int;
      cf_body = Some (mk_call "bit_and" fn_ty [ cint 1; cint 2 ] ty_int);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 92;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc user_func; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main_func; cd_loc = loc; cd_doc = None };
    ]
  in
  let resolved = Blorp.Core_resolve.resolve_program prog in
  let body =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> Alcotest.fail "expected user function and main"
  in
  match body.desc with
  | CCall (CKUser (name, Some def_id), _, _) ->
      Alcotest.(check string) "user function wins" "bit_and" name;
      Alcotest.(check int) "user def id wins" 91 def_id
  | CCall (CKIntrinsic name, _, _) ->
      Alcotest.failf "user bit_and resolved as intrinsic %s" name
  | _ -> Alcotest.fail "expected bit_and to resolve as a user call"

let test_resolve_debug_reflection_calls_to_intrinsics () =
  let ty_string = TyNamed ("String", []) in
  let ty_bool = TyNamed ("Bool", []) in
  let cases =
    [
      ("type_name", ty_string);
      ("std_debug__type_name", ty_string);
      ("is_heap", ty_bool);
      ("std_debug__is_heap", ty_bool);
    ]
  in
  List.iter
    (fun (name, ret_ty) ->
      let fn_ty =
        TyFunc { params = [ ty_int ]; return = ret_ty; is_pure = true }
      in
      let body = mk_call name fn_ty [ cint 1 ] ret_ty in
      let prog = program_with_func "main" [] ret_ty (Some body) in
      let resolved = Blorp.Core_resolve.resolve_program prog in
      let expected =
        match name with
        | "std_debug__type_name" -> "type_name"
        | "std_debug__is_heap" -> "is_heap"
        | _ -> name
      in
      expect_intrinsic_call name expected (get_func_body resolved))
    cases

let test_resolve_imported_debug_reflection_call_to_intrinsic () =
  let ty_string = TyNamed ("String", []) in
  let fn_ty =
    TyFunc { params = [ ty_int ]; return = ty_string; is_pure = true }
  in
  let body = mk_call "type_name" fn_ty [ cint 1 ] ty_string in
  let prog = program_with_func "main" [] ty_string (Some body) in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "type_name" ("std/debug", "type_name");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  expect_intrinsic_call "imported type_name" "type_name"
    (get_func_body resolved)

let test_resolve_qualified_debug_reflection_call_to_intrinsic () =
  let ty_bool = TyNamed ("Bool", []) in
  let fn_ty =
    TyFunc { params = [ ty_int ]; return = ty_bool; is_pure = true }
  in
  let module_alias = cvar "dbg" (TyNamed ("Module", [])) in
  let callee = mk (CField (module_alias, "is_heap")) fn_ty in
  let body = mk (CCall (CKUnknown, callee, [ cint 1 ])) ty_bool in
  let prog = program_with_func "main" [] ty_bool (Some body) in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "dbg" ("std/debug", "");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  expect_intrinsic_call "qualified is_heap" "is_heap" (get_func_body resolved)

let test_resolve_user_debug_reflection_name_before_intrinsic () =
  let ty_string = TyNamed ("String", []) in
  let fn_ty =
    TyFunc { params = [ ty_int ]; return = ty_string; is_pure = true }
  in
  let user_func : core_func =
    {
      cf_name = "type_name";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_string;
      cf_body = Some (cstr "custom");
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 93;
    }
  in
  let main_func : core_func =
    {
      cf_name = "main";
      cf_type_params = [];
      cf_module = None;
      cf_params = [];
      cf_return_ty = ty_string;
      cf_body = Some (mk_call "type_name" fn_ty [ cint 1 ] ty_string);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 94;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc user_func; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main_func; cd_loc = loc; cd_doc = None };
    ]
  in
  let resolved = Blorp.Core_resolve.resolve_program prog in
  let body =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> Alcotest.fail "expected user function and main"
  in
  match body.desc with
  | CCall (CKUser (name, Some def_id), _, _) ->
      Alcotest.(check string) "user function wins" "type_name" name;
      Alcotest.(check int) "user def id wins" 93 def_id
  | CCall (CKIntrinsic name, _, _) ->
      Alcotest.failf "user type_name resolved as intrinsic %s" name
  | _ -> Alcotest.fail "expected type_name to resolve as a user call"

let test_resolve_imported_matrix_kernels_to_builtins () =
  let tensor elem dims =
    TyNamed ("Tensor", elem :: List.map (fun n -> TyConstInt n) dims)
  in
  let matrix = cvar "m" (tensor ty_int [ 2; 3 ]) in
  let vector_2 = cvar "v2" (tensor ty_int [ 2 ]) in
  let vector_3 = cvar "v3" (tensor ty_int [ 3 ]) in
  let cases =
    [
      ( "matvec",
        "blorp_tensor_matvec",
        [ matrix; vector_3 ],
        tensor ty_int [ 2 ] );
      ( "matvec_t",
        "blorp_tensor_matvec_t",
        [ matrix; vector_2 ],
        tensor ty_int [ 3 ] );
      ( "outer",
        "blorp_tensor_outer",
        [ vector_2; vector_3 ],
        tensor ty_int [ 2; 3 ] );
    ]
  in
  List.iter
    (fun (name, expected, args, ret_ty) ->
      let fn_ty =
        TyFunc
          {
            params = List.map (fun arg -> arg.ty) args;
            return = ret_ty;
            is_pure = true;
          }
      in
      let body = mk_call name fn_ty args ret_ty in
      let prog = program_with_func "main" [] ret_ty (Some body) in
      let import_aliases = Hashtbl.create 4 in
      Hashtbl.replace import_aliases name ("std/matrix", name);
      let resolved =
        Blorp.Core_resolve.resolve_program ~import_aliases
          ~module_imports:(Hashtbl.create 0) prog
      in
      expect_builtin_call name expected (get_func_body resolved))
    cases

let test_resolve_foreign_call () =
  (* foreign:
       func c_abs(x: Int) -> Int = "abs"
     func f() -> Int: c_abs(-5) — call becomes CKForeign "abs" *)
  let abs_func : core_func =
    {
      cf_name = "c_abs";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = None;
      cf_is_pure = true;
      cf_kind =
        CFForeign
          {
            c_name = "abs";
            includes = [];
            link_flags = [];
            arg_passing = ForeignDefaultArgs [];
          };
      cf_def_id = 0;
    }
  in
  let abs_fty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let neg5 = mk (CUn (Neg, cint 5)) ty_int in
  let call = mk_call "c_abs" abs_fty [ neg5 ] ty_int in
  let f_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc abs_func; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc f_func; cd_loc = loc; cd_doc = None };
    ]
  in
  let resolved = Blorp.Core_resolve.resolve_program prog in
  let f_resolved =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected two funcs"
  in
  match f_resolved.desc with
  | CCall
      ( CKForeign { fc_c_name = "abs"; fc_arg_passing = ForeignDefaultArgs [] },
        _,
        _ ) ->
      ()
  | _ -> Alcotest.fail "expected CKForeign \"abs\""

let test_resolve_imported_unresolved_stays_unknown () =
  (* A type-dispatched stdlib builtin (e.g. [sum], [product]) is declared
     as a generic signature with a [builtin] body, imported into the main
     program, and handled by [Core_specialize] rather than [user_funcs] or
     the [Codegen_builtins] table. When resolve can't pin it to a concrete
     user/foreign/builtin function, it must stay [CKUnknown] (not downgrade
     to [CKClosure]) so specialize can transform it to the per-type C
     function. We distinguish this from a local parameter of function type
     by checking whether the name appears in an import table. *)
  let unknown_fty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = false }
  in
  let call = mk_call "sum" unknown_fty [ cint 1 ] ty_int in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None } ] in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "sum" ("std/vector", "sum");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  let body = get_func_body resolved in
  match body.desc with
  | CCall (CKUnknown, _, _) -> ()
  | _ ->
      Alcotest.fail "expected CKUnknown for imported-but-unresolved bare name"

let test_resolve_qualified_module_alias_builtin () =
  (* `import: list as L` followed by `L.length(xs)` should resolve through
     the shared module-function path, not a one-off builtin fallback. *)
  let list_ty = TyNamed ("List", [ ty_int ]) in
  let list_len_fty =
    TyFunc { params = [ list_ty ]; return = ty_int; is_pure = true }
  in
  let xs = cvar "xs" list_ty in
  let module_alias = cvar "L" (TyNamed ("Module", [])) in
  let callee = mk (CField (module_alias, "length")) list_len_fty in
  let call = mk (CCall (CKUnknown, callee, [ xs ])) ty_int in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None } ] in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "L" ("std/list", "");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  expect_intrinsic_call "L.length" "list_len" (get_func_body resolved)

let test_resolve_qualified_call_prefers_carried_def_id_name () =
  let reverse_func : core_func =
    {
      cf_name = "std_list__reverse__pure";
      cf_type_params = [];
      cf_module = Some "std/list";
      cf_params = [ { cp_name = Var.named "xs"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (cint 42);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 77;
    }
  in
  let call_ty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let module_alias = mk (CVar (Var.named "L")) (TyNamed ("Module", [])) in
  let callee = mk (CField (module_alias, "reverse")) call_ty in
  let call =
    mk
      (CCall (CKSelectedDirect reverse_func.cf_def_id, callee, [ cint 1 ]))
      ty_int
  in
  let main_f : core_func =
    {
      cf_name = "main";
      cf_type_params = [];
      cf_module = None;
      cf_params = [];
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc reverse_func; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main_f; cd_loc = loc; cd_doc = None };
    ]
  in
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases:(Hashtbl.create 0)
      ~module_imports:(Hashtbl.create 0) prog
  in
  let main_resolved =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected selected qualified call in main"
  in
  match main_resolved.desc with
  | CCall (CKUser (name, def_id), _, _) ->
      Alcotest.(check string)
        "canonical qualified selected name" "std_list__reverse__pure" name;
      Alcotest.(check (option int)) "selected def id" (Some 77) def_id
  | _ -> Alcotest.fail "expected qualified CKUser selected by carried def id"

let test_resolve_local_value_shadows_module_alias_call () =
  (* If a local value has the same spelling as an imported module alias,
     qualified field calls on the local value must remain closure calls. The
     import alias is only visible when the qualifier is not locally bound. *)
  let ty_str = TyNamed ("String", []) in
  let run_fty =
    TyFunc { params = [ ty_str ]; return = ty_str; is_pure = true }
  in
  let local_alias = cvar "L" (TyNamed ("Runner", [])) in
  let callee = mk (CField (local_alias, "run")) run_fty in
  let call = mk (CCall (CKUnknown, callee, [ cstr "ok" ])) ty_str in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params =
        [
          {
            cp_name = Var.named "L";
            cp_ty = TyNamed ("Runner", []);
            cp_loc = loc;
          };
        ];
      cf_module = None;
      cf_return_ty = ty_str;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None } ] in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "L" ("std/list", "");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  match (get_func_body resolved).desc with
  | CCall (CKClosure, { desc = CField ({ desc = CVar v; _ }, "run"); _ }, _) ->
      Alcotest.(check string) "local qualifier preserved" "L" v.vname
  | CCall (CKBuiltin name, _, _) ->
      Alcotest.failf "local qualifier incorrectly resolved as builtin %s" name
  | CCall (CKIntrinsic name, _, _) ->
      Alcotest.failf "local qualifier incorrectly resolved as intrinsic %s" name
  | CCall (CKUser (name, _), _, _) ->
      Alcotest.failf "local qualifier incorrectly resolved as user %s" name
  | CCall (CKUnknown, _, _) ->
      Alcotest.fail "local qualified call stayed CKUnknown"
  | _ -> Alcotest.fail "expected qualified closure call"

let test_resolve_resource_scope_binding_shadows_module_alias_call () =
  (* Resource-scope bindings are local bindings too. They must shadow imported
     module aliases in the body and cleanup, but not in the acquisition. *)
  let list_ty = TyNamed ("List", [ ty_int ]) in
  let list_len_fty =
    TyFunc { params = [ list_ty ]; return = ty_int; is_pure = true }
  in
  let xs = cvar "xs" list_ty in
  let module_alias = cvar "L" (TyNamed ("Module", [])) in
  let callee = mk (CField (module_alias, "length")) list_len_fty in
  let call = mk (CCall (CKUnknown, callee, [ xs ])) ty_int in
  let runner_ty = TyNamed ("Runner", []) in
  let scope =
    mk
      (CResourceScope
         {
           rs_var = Var.named "L";
           rs_ty = runner_ty;
           rs_acquire = cvar "make_runner" runner_ty;
           rs_body = call;
           rs_cleanup = mk CVoid ty_void;
         })
      ty_int
  in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params =
        [ { cp_name = Var.named "xs"; cp_ty = list_ty; cp_loc = loc } ];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some scope;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None } ] in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "L" ("std/list", "");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  match (get_func_body resolved).desc with
  | CResourceScope
      {
        rs_body =
          {
            desc =
              CCall
                ( CKClosure,
                  { desc = CField ({ desc = CVar v; _ }, "length"); _ },
                  _ );
            _;
          };
        _;
      } ->
      Alcotest.(check string) "resource qualifier preserved" "L" v.vname
  | CResourceScope { rs_body = { desc = CCall (CKBuiltin name, _, _); _ }; _ }
    ->
      Alcotest.failf "resource qualifier incorrectly resolved as builtin %s"
        name
  | CResourceScope { rs_body = { desc = CCall (CKIntrinsic name, _, _); _ }; _ }
    ->
      Alcotest.failf "resource qualifier incorrectly resolved as intrinsic %s"
        name
  | CResourceScope { rs_body = { desc = CCall (CKUnknown, _, _); _ }; _ } ->
      Alcotest.fail "resource qualified call stayed CKUnknown"
  | CResourceScope _ -> Alcotest.fail "expected resource scope body call"
  | _ -> Alcotest.fail "expected resource scope"

let test_resolve_qualified_string_length_uses_intrinsic () =
  let ty_str = TyNamed ("String", []) in
  let len_fty =
    TyFunc { params = [ ty_str ]; return = ty_int; is_pure = true }
  in
  let s = cvar "s" ty_str in
  let module_alias = cvar "Str" (TyNamed ("Module", [])) in
  let callee = mk (CField (module_alias, "length")) len_fty in
  let call = mk (CCall (CKUnknown, callee, [ s ])) ty_int in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None } ] in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "Str" ("std/string", "");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  expect_intrinsic_call "Str.length" "string_len" (get_func_body resolved)

let test_resolve_qualified_bytes_length_uses_intrinsic () =
  let bytes_ty = TyNamed ("Bytes", []) in
  let len_fty =
    TyFunc { params = [ bytes_ty ]; return = ty_int; is_pure = true }
  in
  let b = cvar "b" bytes_ty in
  let module_alias = cvar "B" (TyNamed ("Module", [])) in
  let callee = mk (CField (module_alias, "length")) len_fty in
  let call = mk (CCall (CKUnknown, callee, [ b ])) ty_int in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None } ] in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "B" ("std/bytes", "");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  expect_intrinsic_call "B.length" "bytes_len" (get_func_body resolved)

let test_resolve_qualified_dict_length_uses_intrinsic_not_c_builtin () =
  (* `import: dict as D` followed by `D.length(d)` must stay on the
     qualified-call resolver. Length is IR-backed, so it should become the
     dict_len intrinsic directly instead of detouring through the old
     blorp_dict_length C wrapper or an unmaterialized generic std function. *)
  let ty_str = TyNamed ("String", []) in
  let dict_ty = TyNamed ("Dict", [ ty_str; ty_int ]) in
  let dict_len_fty =
    TyFunc { params = [ dict_ty ]; return = ty_int; is_pure = true }
  in
  let d = cvar "d" dict_ty in
  let module_alias = cvar "D" (TyNamed ("Module", [])) in
  let callee = mk (CField (module_alias, "length")) dict_len_fty in
  let call = mk (CCall (CKUnknown, callee, [ d ])) ty_int in
  let generic_length : core_func =
    {
      cf_name = "std_dict__length";
      cf_type_params = tparams [ "K"; "V" ];
      cf_params =
        [ { cp_name = Var.named "self"; cp_ty = dict_ty; cp_loc = loc } ];
      cf_module = Some "std/dict";
      cf_return_ty = ty_int;
      cf_body = Some (cint 0);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 99;
    }
  in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc generic_length; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None };
    ]
  in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "D" ("std/dict", "");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  let body =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected helper plus body function"
  in
  expect_intrinsic_call "D.length" "dict_len" body

let test_resolve_qualified_set_length_uses_intrinsic_not_c_builtin () =
  (* Same migration path as dict length: module-qualified set length should
     resolve to IR directly, not the removed blorp_set_length runtime shim. *)
  let set_ty = TyNamed ("Set", [ ty_int ]) in
  let set_len_fty =
    TyFunc { params = [ set_ty ]; return = ty_int; is_pure = true }
  in
  let s = cvar "s" set_ty in
  let module_alias = cvar "S" (TyNamed ("Module", [])) in
  let callee = mk (CField (module_alias, "length")) set_len_fty in
  let call = mk (CCall (CKUnknown, callee, [ s ])) ty_int in
  let generic_length : core_func =
    {
      cf_name = "std_set__length";
      cf_type_params = tparams [ "T" ];
      cf_params =
        [ { cp_name = Var.named "self"; cp_ty = set_ty; cp_loc = loc } ];
      cf_module = Some "std/set";
      cf_return_ty = ty_int;
      cf_body = Some (cint 0);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 98;
    }
  in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc generic_length; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None };
    ]
  in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "S" ("std/set", "");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  let body =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected helper plus body function"
  in
  expect_intrinsic_call "S.length" "set_len" body

let test_resolve_qualified_module_alias_value () =
  (* `import: ./helpers/constants_mod as CM` followed by `CM.MY_INT`
     should resolve to the flattened module global, not survive as a
     field access on a nonexistent runtime module value. *)
  let module_alias = cvar "CM" (TyNamed ("Module", [])) in
  let body = mk (CField (module_alias, "MY_INT")) ty_int in
  let global_var : core_var =
    {
      cv_name = Var.named "__helpers_constants_mod__MY_INT";
      cv_module = Some "helpers/constants_mod";
      cv_ty = ty_int;
      cv_init = cint 42;
      cv_is_mutable = false;
      cv_is_const = true;
      cv_def_id = 10;
    }
  in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDVar global_var; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None };
    ]
  in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "CM" ("./helpers/constants_mod", "");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  let body =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected global var plus function"
  in
  match body.desc with
  | CVar v ->
      Alcotest.(check string)
        "qualified global name" "__helpers_constants_mod__MY_INT" v.vname
  | _ -> Alcotest.fail "expected qualified module value to resolve to CVar"

let test_resolve_selective_import_alias_builtin () =
  (* `import: list: length as list_length` followed by
     `list_length(xs)` uses the same resolver as qualified module calls. *)
  let list_ty = TyNamed ("List", [ ty_int ]) in
  let list_len_fty =
    TyFunc { params = [ list_ty ]; return = ty_int; is_pure = true }
  in
  let xs = cvar "xs" list_ty in
  let call = mk_call "list_length" list_len_fty [ xs ] ty_int in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None } ] in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "list_length" ("std/list", "length");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  expect_intrinsic_call "list_length" "list_len" (get_func_body resolved)

let test_resolve_prefixed_runtime_builtin_beats_std_signature () =
  (* Imported runtime-backed std functions can arrive as already-prefixed
     names after the child [CVar] rewrite. They must still resolve through
     the builtin table rather than the std signature declaration, otherwise
     emission calls an undeclared [std_stream__from_list] wrapper. *)
  let list_ty = TyNamed ("List", [ ty_int ]) in
  let stream_ty = TyNamed ("Stream", [ ty_int ]) in
  let from_list_ty =
    TyFunc { params = [ list_ty ]; return = stream_ty; is_pure = true }
  in
  let call =
    mk_call "std_stream__from_list" from_list_ty [ cvar "xs" list_ty ] stream_ty
  in
  let std_sig : core_func =
    {
      cf_name = "std_stream__from_list";
      cf_type_params = tparams [ "T" ];
      cf_params = [];
      cf_module = Some "std/stream";
      cf_return_ty = stream_ty;
      cf_body = None;
      cf_is_pure = false;
      cf_kind = CFBuiltin;
      cf_def_id = 1;
    }
  in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = stream_ty;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc std_sig; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None };
    ]
  in
  let resolved = Blorp.Core_resolve.resolve_program prog in
  match resolved with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      expect_builtin_call "std_stream__from_list" "blorp_stream_from_list" body
  | _ -> Alcotest.fail "expected std signature plus function"

let test_resolve_synthesized_monomorphic_runtime_builtin_stays_builtin () =
  (* Core_synth gives monomorphized runtime-backed std wrappers a body before
     this pass. Even if they no longer carry CFBuiltin by then, they must still
     resolve as CKBuiltin so emission can call the runtime helper directly with
     layout metadata instead of routing through a user wrapper. *)
  let ty_string = TyNamed ("String", []) in
  let stream_int = TyNamed ("Stream", [ ty_int ]) in
  let stream_string = TyNamed ("Stream", [ ty_string ]) in
  let callback_ty =
    TyFunc { params = [ ty_int ]; return = ty_string; is_pure = true }
  in
  let map_ty =
    TyFunc
      {
        params = [ stream_int; callback_ty ];
        return = stream_string;
        is_pure = false;
      }
  in
  let synthesized_map : core_func =
    {
      cf_name = "std_stream__map__mono_Int_String";
      cf_type_params = [];
      cf_module = Some "std/stream";
      cf_params = [];
      cf_return_ty = stream_string;
      cf_body = Some (cvar "dummy" stream_string);
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 404;
    }
  in
  let call =
    mk_call "std_stream__map__mono_Int_String" map_ty
      [ cvar "s" stream_int; cvar "f" callback_ty ]
      stream_string
  in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = stream_string;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc synthesized_map; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None };
    ]
  in
  let resolved = Blorp.Core_resolve.resolve_program prog in
  match resolved with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      expect_builtin_call "std_stream__map__mono_Int_String" "blorp_stream_map"
        body
  | _ -> Alcotest.fail "expected synthesized builtin plus function"

let test_runtime_backed_std_function_reference_stays_user_func () =
  (* Non-monomorphic runtime-backed std functions still need an emitted wrapper:
     they can be passed as first-class function values, e.g.
     [words.map(upper)]. *)
  let ty_string = TyNamed ("String", []) in
  let upper_ty =
    TyFunc { params = [ ty_string ]; return = ty_string; is_pure = true }
  in
  let upper_func : core_func =
    {
      cf_name = "std_string__upper";
      cf_type_params = [];
      cf_module = Some "std/string";
      cf_params = [];
      cf_return_ty = ty_string;
      cf_body = Some (cvar "dummy" ty_string);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 405;
    }
  in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = upper_ty;
      cf_body = Some (cvar "upper" upper_ty);
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc upper_func; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None };
    ]
  in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "upper" ("std/string", "upper");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  match resolved with
  | [ _; { cd_desc = CDFunc { cf_body = Some { desc = CVar v; _ }; _ }; _ } ] ->
      Alcotest.(check string) "function ref name" "std_string__upper" v.vname;
      Alcotest.(check (option int)) "function ref def id" (Some 405) v.vdef_id
  | _ -> Alcotest.fail "expected function body to be an imported CVar"

let test_resolve_qualified_module_alias_unprefixed_module_func () =
  (* Body-synthesized std builtin wrappers can intentionally remain unprefixed
     at the Core name level. Qualified calls must still resolve through the
     module table instead of falling back to closure-field emission like
     [F->fixed]. *)
  let ty_float = TyNamed ("Float", []) in
  let ty_fixed = TyNamed ("Fixed", []) in
  let fixed_ty =
    TyFunc { params = [ ty_float; ty_int ]; return = ty_fixed; is_pure = true }
  in
  let fixed_func : core_func =
    {
      cf_name = "fixed";
      cf_type_params = [];
      cf_module = Some "std/fixed";
      cf_params = [];
      cf_return_ty = ty_fixed;
      cf_body = Some (cvar "dummy" ty_fixed);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 101;
    }
  in
  let module_alias = mk (CVar (Var.named "F")) (TyNamed ("Module", [])) in
  let callee = mk (CField (module_alias, "fixed")) fixed_ty in
  let call =
    mk (CCall (CKUnknown, callee, [ cvar "value" ty_float; cint 2 ])) ty_fixed
  in
  let main_f : core_func =
    {
      cf_name = "main";
      cf_type_params = [];
      cf_module = None;
      cf_params = [];
      cf_return_ty = ty_fixed;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc fixed_func; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main_f; cd_loc = loc; cd_doc = None };
    ]
  in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "F" ("std/fixed", "");
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases
      ~module_imports:(Hashtbl.create 0) prog
  in
  let body =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected module func plus main"
  in
  match body.desc with
  | CCall (CKUser (name, def_id), _, _) ->
      Alcotest.(check string) "actual emitted name" "fixed" name;
      Alcotest.(check (option int)) "module func def id" (Some 101) def_id
  | CCall (CKClosure, _, _) ->
      Alcotest.fail "qualified module func resolved as closure"
  | _ -> Alcotest.fail "expected qualified module func to resolve as CKUser"

let test_module_owned_unprefixed_func_does_not_pollute_bare_name () =
  (* An unprefixed module-owned wrapper such as std/fixed.to_float must not be
     registered as a global bare [to_float]; otherwise unrelated module bodies
     can call the Fixed wrapper with Float16/Int/Float arguments. *)
  let ty_float = TyNamed ("Float", []) in
  let ty_float16 = TyNamed ("Float16", []) in
  let fixed_to_float : core_func =
    {
      cf_name = "to_float";
      cf_type_params = [];
      cf_module = Some "std/fixed";
      cf_params = [];
      cf_return_ty = ty_float;
      cf_body = Some (cvar "dummy" ty_float);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 202;
    }
  in
  let call_ty =
    TyFunc { params = [ ty_float16 ]; return = ty_float; is_pure = true }
  in
  let body =
    mk
      (CCall (CKUnknown, cvar "to_float" call_ty, [ cvar "x" ty_float16 ]))
      ty_float
  in
  let float16_method : core_func =
    {
      cf_name = "to_float";
      cf_type_params = [];
      cf_module = Some "std/float16";
      cf_params =
        [ { cp_name = Var.named "x"; cp_ty = ty_float16; cp_loc = loc } ];
      cf_return_ty = ty_float;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 203;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc fixed_to_float; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc float16_method; cd_loc = loc; cd_doc = None };
    ]
  in
  let resolved = Blorp.Core_resolve.resolve_program prog in
  match resolved with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      expect_builtin_call "bare to_float" "blorp_to_float" body
  | _ -> Alcotest.fail "expected two module functions"

let test_resolve_ufcs_by_first_arg_builtin () =
  (* A bare `get(s, i)` is not a prelude builtin. For String it resolves
     through the first-argument UFCS module candidates to std/string.get. *)
  let ty_str = TyNamed ("String", []) in
  let ty_char = TyNamed ("Char", []) in
  let ret_ty = TyNamed ("Option", [ ty_char ]) in
  let get_fty =
    TyFunc { params = [ ty_str; ty_int ]; return = ret_ty; is_pure = true }
  in
  let s = cvar "s" ty_str in
  let call = mk_call "get" get_fty [ s; cint 0 ] ret_ty in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ret_ty;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None } ] in
  let resolved = Blorp.Core_resolve.resolve_program prog in
  expect_builtin_call "String.get UFCS" "blorp_string_get_opt"
    (get_func_body resolved)

let test_resolve_monomorphized_bodyless_builtin () =
  (* Post-mono builtins that stay bodyless must still resolve to their
     runtime C builtin. Otherwise [Core_closure] treats the function-typed
     callee as a first-class closure and emits calls to a nonexistent static
     closure symbol such as [std_vector__map__mono_3_Int_Int]. *)
  let vector_int_3 = TyArray (ty_int, [ TyConstInt 3 ]) in
  let map_fty =
    TyFunc
      {
        params =
          [
            vector_int_3;
            TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true };
          ];
        return = vector_int_3;
        is_pure = false;
      }
  in
  let builtin_map : core_func =
    {
      cf_name = "std_vector__map__mono_3_Int_Int";
      cf_type_params = [];
      cf_module = Some "std/vector";
      cf_params =
        [
          { cp_name = Var.named "arr"; cp_ty = vector_int_3; cp_loc = loc };
          {
            cp_name = Var.named "f";
            cp_ty =
              TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true };
            cp_loc = loc;
          };
        ];
      cf_return_ty = vector_int_3;
      cf_body = None;
      cf_is_pure = false;
      cf_kind = CFBuiltin;
      cf_def_id = 0;
    }
  in
  let call =
    mk_call "std_vector__map__mono_3_Int_Int" map_fty
      [
        cvar "v" vector_int_3;
        cvar "double"
          (TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true });
      ]
      vector_int_3
  in
  let body_func : core_func =
    {
      cf_name = "caller";
      cf_type_params = [];
      cf_module = None;
      cf_params = [];
      cf_return_ty = vector_int_3;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc builtin_map; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None };
    ]
  in
  let resolved = Blorp.Core_resolve.resolve_program prog in
  let body =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected builtin plus caller"
  in
  expect_builtin_call "monomorphized std/vector.map" "blorp_vector_map" body

let test_bodyless_builtin_overloads_resolve_by_call_site () =
  (* Bodyless std declarations can share the same bare [cf_name] across
     modules. They are not globally-addressable call targets until the call
     site supplies an import/module/type context. *)
  let ty_string = TyNamed ("String", []) in
  let option_char = TyNamed ("Option", [ TyNamed ("Char", []) ]) in
  let tensor_int_3 = TyArray (ty_int, [ TyConstInt 3 ]) in
  let option_int = TyNamed ("Option", [ ty_int ]) in
  let string_get : core_func =
    {
      cf_name = "get";
      cf_type_params = [];
      cf_module = Some "std/string";
      cf_params =
        [
          { cp_name = Var.named "self"; cp_ty = ty_string; cp_loc = loc };
          { cp_name = Var.named "index"; cp_ty = ty_int; cp_loc = loc };
        ];
      cf_return_ty = option_char;
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFBuiltin;
      cf_def_id = 0;
    }
  in
  let tensor_get : core_func =
    {
      cf_name = "get";
      cf_type_params = [];
      cf_module = Some "std/tensor";
      cf_params =
        [
          { cp_name = Var.named "arr"; cp_ty = tensor_int_3; cp_loc = loc };
          { cp_name = Var.named "index"; cp_ty = ty_int; cp_loc = loc };
        ];
      cf_return_ty = option_int;
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFBuiltin;
      cf_def_id = 0;
    }
  in
  let get_fty =
    TyFunc
      { params = [ ty_string; ty_int ]; return = option_char; is_pure = true }
  in
  let call = mk_call "get" get_fty [ cvar "s" ty_string; cint 0 ] option_char in
  let caller : core_func =
    {
      cf_name = "__tests_test__caller";
      cf_type_params = [];
      cf_module = Some "./tests/test";
      cf_params = [];
      cf_return_ty = option_char;
      cf_body = Some call;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc string_get; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc tensor_get; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc caller; cd_loc = loc; cd_doc = None };
    ]
  in
  let module_imports = Hashtbl.create 1 in
  let aliases = Hashtbl.create 1 in
  Hashtbl.replace aliases "get" ("std/string", "get");
  Hashtbl.replace module_imports "./tests/test" aliases;
  let resolved = Blorp.Core_resolve.resolve_program ~module_imports prog in
  let body =
    match resolved with
    | [ _; _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected two builtins plus caller"
  in
  expect_builtin_call "overloaded bare get" "blorp_string_get_opt" body

let test_resolve_unimported_functype_is_closure () =
  (* A bare [CVar] with [TyFunc] type that is NOT imported is assumed to
     be a local parameter (closure value), so it classifies as
     [CKClosure]. This matches std-library patterns like
     [measure_memory(f: () -> Void)] where [f()] inside the body should
     emit as a closure call. *)
  let unknown_fty = TyFunc { params = []; return = ty_int; is_pure = false } in
  let call = mk_call "f" unknown_fty [] ty_int in
  let body_func : core_func =
    {
      cf_name = "caller";
      cf_type_params = [];
      cf_module = None;
      cf_params =
        [ { cp_name = Var.named "f"; cp_ty = unknown_fty; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None } ] in
  let resolved = Blorp.Core_resolve.resolve_program prog in
  let body = get_func_body resolved in
  match body.desc with
  | CCall (CKClosure, _, _) -> ()
  | _ -> Alcotest.fail "expected CKClosure for unimported TyFunc bare name"

let test_resolve_non_cvar_functype_becomes_closure () =
  (* A non-[CVar] callee (e.g. a field access returning a function, or
     a parameter holding a closure) still classifies as [CKClosure] —
     that's what the emit path's closure-call shape is for. *)
  let unknown_fty = TyFunc { params = []; return = ty_int; is_pure = false } in
  (* Callee: obj.method returning a function — not a bare CVar. *)
  let obj = cvar "obj" (TyNamed ("SomeRec", [])) in
  let callee = { desc = CField (obj, "method"); ty = unknown_fty; loc } in
  let call = { desc = CCall (CKUnknown, callee, []); ty = ty_int; loc } in
  let body_func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None } ] in
  let resolved = Blorp.Core_resolve.resolve_program prog in
  let body = get_func_body resolved in
  match body.desc with
  | CCall (CKClosure, _, _) -> ()
  | _ -> Alcotest.fail "expected CKClosure for non-CVar TyFunc callee"

let test_resolve_recurses_into_children () =
  (* Nested calls: print(inc(5)) — both must be tagged. *)
  let inc : core_func =
    {
      cf_name = "inc";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (cint 42);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let print_f : core_func =
    {
      cf_name = "print";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_void;
      cf_body = None;
      cf_is_pure = false;
      cf_kind =
        CFForeign
          {
            c_name = "c_print";
            includes = [];
            link_flags = [];
            arg_passing = ForeignDefaultArgs [];
          };
      cf_def_id = 0;
    }
  in
  let inc_fty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let print_fty =
    TyFunc { params = [ ty_int ]; return = ty_void; is_pure = false }
  in
  let inc_call = mk_call "inc" inc_fty [ cint 5 ] ty_int in
  let print_call = mk_call "print" print_fty [ inc_call ] ty_void in
  let main_f : core_func =
    {
      cf_name = "main";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_void;
      cf_body = Some print_call;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc inc; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc print_f; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main_f; cd_loc = loc; cd_doc = None };
    ]
  in
  let resolved = Blorp.Core_resolve.resolve_program prog in
  let main_body =
    match resolved with
    | [ _; _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected three funcs"
  in
  (* Outer print call should be CKForeign "c_print" *)
  match main_body.desc with
  | CCall
      ( CKForeign
          { fc_c_name = "c_print"; fc_arg_passing = ForeignDefaultArgs [] },
        _,
        [ inner_arg ] ) -> (
      (* Inner inc call should be CKUser "inc" *)
      match inner_arg.desc with
      | CCall (CKUser ("inc", _), _, _) -> ()
      | _ -> Alcotest.fail "inner call not tagged CKUser")
  | _ -> Alcotest.fail "outer call not tagged CKForeign"

(* ============================================================================
   Module-scope isolation for import rewriting
   ============================================================================ *)

(* Regression: a function in a module whose name contains an underscore
   (e.g. std/sorted_map, std/crypto_random) must have its aliased imports
   resolved correctly. Before [cf_module] existed, resolve parsed the
   mangled name to recover the module path, and because sanitize_module_name
   is lossy (both '/' and '_' survive as '_'), std_sorted_map__foo extracted
   as std/sorted/map — a nonexistent module. Aliased imports like
   list: get as list_get fell through to CKClosure.

   Now that [cf_module] carries the authoritative module identity, the name
   shape is irrelevant for resolution — cf_module tells resolve exactly
   which module's import table to consult. *)

(** Regression: when resolving a module's own body, the main program's
    [import_aliases] must not leak in. Otherwise a bare identifier that
    happens to shadow an imported name (e.g. a parameter named [field]
    inside [std/csv] when the main program imported [codec.field]) gets
    silently rewritten to the prefixed module name. *)
let test_resolve_underscored_module_path () =
  let list_ty = TyNamed ("List", [ ty_int ]) in
  let list_len_fty =
    TyFunc { params = [ list_ty ]; return = ty_int; is_pure = true }
  in
  let xs = cvar "xs" list_ty in
  let call = mk_call "list_length" list_len_fty [ xs ] ty_int in
  let body_func : core_func =
    {
      cf_name = "std_sorted_map__min";
      cf_type_params = [];
      cf_module = Some "std/sorted_map";
      cf_params =
        [ { cp_name = Var.named "xs"; cp_ty = list_ty; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None } ] in
  (* Module imports map keyed by the TRUE module name (with underscore). *)
  let module_imports = Hashtbl.create 1 in
  let mod_aliases = Hashtbl.create 4 in
  Hashtbl.replace mod_aliases "list_length" ("std/list", "length");
  Hashtbl.replace module_imports "std/sorted_map" mod_aliases;
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases:(Hashtbl.create 0)
      ~module_imports prog
  in
  let body = get_func_body resolved in
  match body.desc with
  | CCall (CKIntrinsic name, _, _) ->
      Alcotest.(check string) "list_length → list_len" "list_len" name
  | CCall (CKClosure, _, _) ->
      Alcotest.fail
        "list_length downgraded to CKClosure — module path extraction broken"
  | CCall (CKUnknown, _, _) ->
      Alcotest.fail
        "list_length left CKUnknown — module path extraction missed the import"
  | _ -> Alcotest.fail "expected CCall"

(* Regression: resolve must take module identity from [cf_module] on the
   function, NOT by parsing [cf_name]. Before this test, extract_module_path
   reverse-engineered the module name from the mangled function name, which
   was ambiguous for module paths containing underscores. With cf_module as
   the authoritative source, a function's declared origin is used directly.

   Verifies the fix by giving the function an intentionally misleading name
   (that would NOT parse to the correct module path) but the correct
   cf_module — resolve should still route through the right import table. *)
let test_resolve_uses_cf_module_not_name () =
  let list_ty = TyNamed ("List", [ ty_int ]) in
  let list_len_fty =
    TyFunc { params = [ list_ty ]; return = ty_int; is_pure = true }
  in
  let xs = cvar "xs" list_ty in
  let call = mk_call "list_length" list_len_fty [ xs ] ty_int in
  let body_func : core_func =
    {
      (* Intentionally misleading: the mangled name suggests a different module
       than the actual one. cf_module is the authoritative source. *)
      cf_name = "misleading__unrelated_name";
      cf_type_params = [];
      cf_module = Some "std/sorted_map";
      cf_params =
        [ { cp_name = Var.named "xs"; cp_ty = list_ty; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some call;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc body_func; cd_loc = loc; cd_doc = None } ] in
  let module_imports = Hashtbl.create 1 in
  let mod_aliases = Hashtbl.create 4 in
  Hashtbl.replace mod_aliases "list_length" ("std/list", "length");
  Hashtbl.replace module_imports "std/sorted_map" mod_aliases;
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases:(Hashtbl.create 0)
      ~module_imports prog
  in
  let body = get_func_body resolved in
  match body.desc with
  | CCall (CKIntrinsic "list_len", _, _) -> ()
  | CCall (CKIntrinsic other, _, _) ->
      Alcotest.failf "wrong intrinsic name: got %s" other
  | CCall (CKClosure, _, _) ->
      Alcotest.fail "fell through to CKClosure — cf_module not being read"
  | CCall (CKUnknown, _, _) ->
      Alcotest.fail "left CKUnknown — cf_module not being read"
  | _ -> Alcotest.fail "expected CCall"

let test_resolve_param_not_rewritten_by_main_imports () =
  (* prog:
       std/codec:  pure func field(s: String) -> Int: 0
       std/csv:    pure func quote(field: String) -> String: field
     main imports  codec { field }
     — we expect [quote]'s body reference to [field] to stay unchanged
       (it's a parameter, not the imported function). *)
  let ty_str = TyNamed ("String", []) in
  let codec_field : core_func =
    {
      cf_name = "std_codec__field";
      cf_type_params = [];
      cf_module = Some "std/codec";
      cf_params = [ { cp_name = Var.named "s"; cp_ty = ty_str; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (cint 0);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let field_param = Var.named "field" in
  let body = { desc = CVar field_param; ty = ty_str; loc } in
  let csv_quote : core_func =
    {
      cf_name = "std_csv__quote";
      cf_type_params = [];
      cf_module = Some "std/csv";
      cf_params = [ { cp_name = field_param; cp_ty = ty_str; cp_loc = loc } ];
      cf_return_ty = ty_str;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc codec_field; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc csv_quote; cd_loc = loc; cd_doc = None };
    ]
  in
  let import_aliases = Hashtbl.create 4 in
  Hashtbl.replace import_aliases "field" ("std/codec", "field");
  let module_imports = Hashtbl.create 1 in
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases ~module_imports prog
  in
  let quote_body =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected two funcs"
  in
  match quote_body.desc with
  | CVar v ->
      Alcotest.(check string) "param reference not rewritten" "field" v.vname
  | _ -> Alcotest.fail "expected CVar"

let test_resolve_param_not_rewritten_by_module_imports () =
  (* A module's own import table must not override its local binders. This
     mirrors std/toml's [parse(input: String)] shadowing the prelude
     [input(prompt)] function imported from std/io. *)
  let ty_str = TyNamed ("String", []) in
  let io_input : core_func =
    {
      cf_name = "std_io__input";
      cf_type_params = [];
      cf_module = Some "std/io";
      cf_params =
        [ { cp_name = Var.named "prompt"; cp_ty = ty_str; cp_loc = loc } ];
      cf_return_ty = ty_str;
      cf_body = Some (cstr "unused");
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let input_param = Var.named "input" in
  let toml_parse : core_func =
    {
      cf_name = "std_toml__parse";
      cf_type_params = [];
      cf_module = Some "std/toml";
      cf_params = [ { cp_name = input_param; cp_ty = ty_str; cp_loc = loc } ];
      cf_return_ty = ty_str;
      cf_body = Some { desc = CVar input_param; ty = ty_str; loc };
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 2;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc io_input; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc toml_parse; cd_loc = loc; cd_doc = None };
    ]
  in
  let module_imports = Hashtbl.create 1 in
  let toml_imports = Hashtbl.create 1 in
  Hashtbl.replace toml_imports "input" ("std/io", "input");
  Hashtbl.replace module_imports "std/toml" toml_imports;
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases:(Hashtbl.create 0)
      ~module_imports prog
  in
  let parse_body =
    match resolved with
    | [ _; { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> b
    | _ -> Alcotest.fail "expected two funcs"
  in
  match parse_body.desc with
  | CVar v ->
      Alcotest.(check string)
        "module param reference not rewritten" "input" v.vname
  | _ -> Alcotest.fail "expected CVar"

let test_resolve_function_param_call_not_rewritten_by_module_imports () =
  let ty_str = TyNamed ("String", []) in
  let callback_ty =
    TyFunc { params = [ ty_str ]; return = ty_str; is_pure = true }
  in
  let input_param = Var.named "input" in
  let call =
    mk
      (CCall
         ( CKUnknown,
           { desc = CVar input_param; ty = callback_ty; loc },
           [ cstr "ok" ] ))
      ty_str
  in
  let wrapper : core_func =
    {
      cf_name = "std_toml__wrap";
      cf_type_params = [];
      cf_module = Some "std/toml";
      cf_params =
        [ { cp_name = input_param; cp_ty = callback_ty; cp_loc = loc } ];
      cf_return_ty = ty_str;
      cf_body = Some call;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 3;
    }
  in
  let prog = [ { cd_desc = CDFunc wrapper; cd_loc = loc; cd_doc = None } ] in
  let module_imports = Hashtbl.create 1 in
  let toml_imports = Hashtbl.create 1 in
  Hashtbl.replace toml_imports "input" ("std/io", "input");
  Hashtbl.replace module_imports "std/toml" toml_imports;
  let resolved =
    Blorp.Core_resolve.resolve_program ~import_aliases:(Hashtbl.create 0)
      ~module_imports prog
  in
  let body = get_func_body resolved in
  match body.desc with
  | CCall (CKClosure, { desc = CVar v; _ }, _) ->
      Alcotest.(check string)
        "function param callee remains local" "input" v.vname
  | CCall (CKUser (name, _), _, _) ->
      Alcotest.failf "function param incorrectly resolved as user %s" name
  | CCall (CKBuiltin name, _, _) ->
      Alcotest.failf "function param incorrectly resolved as builtin %s" name
  | CCall (CKUnknown, _, _) ->
      Alcotest.fail "function param call stayed CKUnknown"
  | _ -> Alcotest.fail "expected closure call"

(* ============================================================================
   Test suite
   ============================================================================ *)

let suite =
  [
    ( "collect_env",
      [
        Alcotest.test_case "empty" `Quick test_collect_empty;
        Alcotest.test_case "user_func" `Quick test_collect_user_func;
        Alcotest.test_case "user_func_name_by_def_id" `Quick
          test_collect_user_func_indexes_name_by_def_id;
        Alcotest.test_case "duplicate_def_id_marks_id_ambiguous" `Quick
          test_collect_duplicate_def_id_marks_id_ambiguous;
        Alcotest.test_case "foreign_func" `Quick test_collect_foreign_func;
      ] );
    ( "resolve",
      [
        Alcotest.test_case "user_call" `Quick test_resolve_user_call;
        Alcotest.test_case "user_call_prefers_carried_def_id_name" `Quick
          test_resolve_user_call_prefers_carried_def_id_name;
        Alcotest.test_case "user_call_prefers_selected_direct_kind" `Quick
          test_resolve_user_call_prefers_selected_direct_kind;
        Alcotest.test_case "bitwise_calls_to_intrinsics" `Quick
          test_resolve_bitwise_calls_to_intrinsics;
        Alcotest.test_case "user_bitwise_name_before_intrinsic" `Quick
          test_resolve_user_bitwise_name_before_intrinsic;
        Alcotest.test_case "debug_reflection_calls_to_intrinsics" `Quick
          test_resolve_debug_reflection_calls_to_intrinsics;
        Alcotest.test_case "imported_debug_reflection_call_to_intrinsic" `Quick
          test_resolve_imported_debug_reflection_call_to_intrinsic;
        Alcotest.test_case "qualified_debug_reflection_call_to_intrinsic" `Quick
          test_resolve_qualified_debug_reflection_call_to_intrinsic;
        Alcotest.test_case "user_debug_reflection_name_before_intrinsic" `Quick
          test_resolve_user_debug_reflection_name_before_intrinsic;
        Alcotest.test_case "imported_matrix_kernels_to_builtins" `Quick
          test_resolve_imported_matrix_kernels_to_builtins;
        Alcotest.test_case "foreign_call" `Quick test_resolve_foreign_call;
        Alcotest.test_case "imported_unresolved_stays_unknown" `Quick
          test_resolve_imported_unresolved_stays_unknown;
        Alcotest.test_case "qualified_module_alias_builtin" `Quick
          test_resolve_qualified_module_alias_builtin;
        Alcotest.test_case "qualified_call_prefers_carried_def_id_name" `Quick
          test_resolve_qualified_call_prefers_carried_def_id_name;
        Alcotest.test_case "local_value_shadows_module_alias_call" `Quick
          test_resolve_local_value_shadows_module_alias_call;
        Alcotest.test_case "resource_scope_shadows_module_alias_call" `Quick
          test_resolve_resource_scope_binding_shadows_module_alias_call;
        Alcotest.test_case "qualified_string_length_uses_intrinsic" `Quick
          test_resolve_qualified_string_length_uses_intrinsic;
        Alcotest.test_case "qualified_bytes_length_uses_intrinsic" `Quick
          test_resolve_qualified_bytes_length_uses_intrinsic;
        Alcotest.test_case "qualified_dict_length_uses_intrinsic" `Quick
          test_resolve_qualified_dict_length_uses_intrinsic_not_c_builtin;
        Alcotest.test_case "qualified_set_length_uses_intrinsic" `Quick
          test_resolve_qualified_set_length_uses_intrinsic_not_c_builtin;
        Alcotest.test_case "qualified_module_alias_value" `Quick
          test_resolve_qualified_module_alias_value;
        Alcotest.test_case "selective_import_alias_builtin" `Quick
          test_resolve_selective_import_alias_builtin;
        Alcotest.test_case "prefixed_runtime_builtin_beats_std_signature" `Quick
          test_resolve_prefixed_runtime_builtin_beats_std_signature;
        Alcotest.test_case "synthesized_mono_runtime_builtin_stays_builtin"
          `Quick
          test_resolve_synthesized_monomorphic_runtime_builtin_stays_builtin;
        Alcotest.test_case "runtime_backed_std_function_ref_stays_user" `Quick
          test_runtime_backed_std_function_reference_stays_user_func;
        Alcotest.test_case "qualified_unprefixed_module_func" `Quick
          test_resolve_qualified_module_alias_unprefixed_module_func;
        Alcotest.test_case "unprefixed_module_func_not_global" `Quick
          test_module_owned_unprefixed_func_does_not_pollute_bare_name;
        Alcotest.test_case "ufcs_by_first_arg_builtin" `Quick
          test_resolve_ufcs_by_first_arg_builtin;
        Alcotest.test_case "monomorphized_bodyless_builtin" `Quick
          test_resolve_monomorphized_bodyless_builtin;
        Alcotest.test_case "bodyless_builtin_overloads_resolve_by_call_site"
          `Quick test_bodyless_builtin_overloads_resolve_by_call_site;
        Alcotest.test_case "unimported_functype_is_closure" `Quick
          test_resolve_unimported_functype_is_closure;
        Alcotest.test_case "non_cvar_functype_closure" `Quick
          test_resolve_non_cvar_functype_becomes_closure;
        Alcotest.test_case "recurses" `Quick test_resolve_recurses_into_children;
        Alcotest.test_case "main_imports_do_not_leak_into_module" `Quick
          test_resolve_param_not_rewritten_by_main_imports;
        Alcotest.test_case "module_imports_do_not_override_param" `Quick
          test_resolve_param_not_rewritten_by_module_imports;
        Alcotest.test_case "module_imports_do_not_override_function_param"
          `Quick
          test_resolve_function_param_call_not_rewritten_by_module_imports;
        Alcotest.test_case "underscored_module_path" `Quick
          test_resolve_underscored_module_path;
        Alcotest.test_case "uses_cf_module_not_name" `Quick
          test_resolve_uses_cf_module_not_name;
      ] );
  ]
