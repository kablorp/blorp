(** Tests for scoped ParallelVector pipeline recognition and lowering. *)

open Blorp.Ast
open Blorp.Core
module P = Blorp.Core_parallel_vector_pipeline

let loc = dummy_loc
let ty_int = TyNamed ("Int", [])
let ty_void = TyNamed ("Void", [])
let dim4 = TyConstInt 4
let ty_vec elem = TyArray (elem, [ dim4 ])
let ty_parallel_vec elem = TyNamed ("ParallelVector", [ elem; dim4 ])
let ty_func params return = TyFunc { params; return; is_pure = true }
let mk ty desc = { desc; ty; loc }
let cvar name ty = mk ty (CVar (Var.named name))
let void = mk ty_void CVoid
let callback name params return = cvar name (ty_func params return)

let lambda params body return =
  mk
    (ty_func (List.map snd params) return)
    (CLambda
       {
         lam_params = List.map (fun (name, ty) -> (Var.named name, ty)) params;
         lam_body = body;
         lam_return_ty = return;
         lam_is_pure = true;
       })

let call_user def_id name args return_ty =
  mk return_ty
    (CCall
       ( CKUser (name, Some def_id),
         cvar name (ty_func (List.map (fun arg -> arg.ty) args) return_ty),
         args ))

let def_vector_parallel = 1
let def_parallel_vector_map = 2
let def_parallel_vector_map_indexed = 3
let def_parallel_vector_zip_map = 4

let std_func module_path name def_id =
  {
    cf_name = name;
    cf_module = Some module_path;
    cf_type_params = [];
    cf_params = [];
    cf_return_ty = ty_void;
    cf_body = None;
    cf_is_pure = true;
    cf_kind = CFBuiltin;
    cf_def_id = def_id;
  }

let decl_func f = { cd_desc = CDFunc f; cd_loc = loc; cd_doc = None }

let std_decls =
  [
    decl_func (std_func "std/vector" "parallel" def_vector_parallel);
    decl_func (std_func "std/parallel_vector" "map" def_parallel_vector_map);
    decl_func
      (std_func "std/parallel_vector" "map_indexed"
         def_parallel_vector_map_indexed);
    decl_func
      (std_func "std/parallel_vector" "zip_map" def_parallel_vector_zip_map);
  ]

let map_call source f =
  call_user def_parallel_vector_map "map" [ source; f ] source.ty

let map_indexed_call source f =
  call_user def_parallel_vector_map_indexed "map_indexed" [ source; f ]
    source.ty

let zip_map_call source other f =
  call_user def_parallel_vector_zip_map "zip_map" [ source; other; f ] source.ty

let parallel_call source body =
  call_user def_vector_parallel "parallel" [ source; body ] (ty_vec ty_int)

let app_decl body =
  decl_func
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = body.ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 100;
    }

let chunk = cvar "chunk" (ty_parallel_vec ty_int)
let source = cvar "values" (ty_vec ty_int)
let other = cvar "other" (ty_vec ty_int)
let other2 = cvar "other2" (ty_vec ty_int)
let mapper = callback "mapper" [ ty_int ] ty_int
let mapper2 = callback "mapper2" [ ty_int ] ty_int
let indexed_mapper = callback "indexed_mapper" [ TyRange dim4; ty_int ] ty_int
let zipper = callback "zipper" [ ty_int; ty_int ] ty_int
let zipper2 = callback "zipper2" [ ty_int; ty_int ] ty_int

let parallel_expr body =
  parallel_call source
    (lambda [ ("chunk", ty_parallel_vec ty_int) ] body (ty_parallel_vec ty_int))

let fuse_expr expr =
  let reg = Blorp.Codegen_types.create_registry () in
  match P.fuse_program ~reg (std_decls @ [ app_decl expr ]) with
  | _std1 :: _std2 :: _std3 :: _std4 :: { cd_desc = CDFunc f; _ } :: _ -> (
      match f.cf_body with
      | Some body -> body
      | None -> Alcotest.fail "expected app function body")
  | _ -> Alcotest.fail "unexpected fused program shape"

let rec contains_intrinsic name expr =
  match expr.desc with
  | CCall (CKIntrinsic actual, _, _) when actual = name -> true
  | _ ->
      let found = ref false in
      ignore
        (map_children
           (fun child ->
             if contains_intrinsic name child then found := true;
             child)
           expr);
      !found

let lowered_builtin_name expr =
  match expr.desc with
  | CCall (CKBuiltin name, _, _) -> name
  | _ ->
      Alcotest.failf "expected builtin call, got %s"
        (Blorp.Core.pp_to_string expr)

let lowered_callback expr =
  match expr.desc with
  | CCall (CKBuiltin _, _, [ _source; callback ]) -> callback
  | CCall (CKBuiltin _, _, [ _source; _other; callback ]) -> callback
  | _ ->
      Alcotest.failf "expected lowered callback, got %s"
        (Blorp.Core.pp_to_string expr)

let test_map_chain_lowers_to_vmap_parallel () =
  let expr = parallel_expr (map_call (map_call chunk mapper) mapper2) in
  let lowered = fuse_expr expr in
  Alcotest.(check string)
    "builtin" "blorp_vmap_parallel"
    (lowered_builtin_name lowered)

let test_indexed_chain_lowers_to_indexed_vmap_parallel () =
  let expr =
    parallel_expr (map_indexed_call (map_call chunk mapper) indexed_mapper)
  in
  let lowered = fuse_expr expr in
  Alcotest.(check string)
    "builtin" "blorp_vmap_indexed_parallel"
    (lowered_builtin_name lowered)

let test_single_zip_chain_lowers_to_vzip_parallel () =
  let expr =
    parallel_expr (map_call (zip_map_call chunk other zipper) mapper)
  in
  let lowered = fuse_expr expr in
  Alcotest.(check string)
    "builtin" "blorp_vzip_parallel"
    (lowered_builtin_name lowered);
  match (lowered_callback lowered).desc with
  | CLambda lam ->
      Alcotest.(check int) "callback arity" 2 (List.length lam.lam_params);
      Alcotest.(check bool)
        "side vector is not loaded through captured index" false
        (contains_intrinsic "tensor_get_unchecked" lam.lam_body)
  | _ -> Alcotest.fail "expected lowered callback lambda"

let test_reused_zip_vector_lowers_to_vzip_parallel () =
  let expr =
    parallel_expr
      (map_call
         (zip_map_call (zip_map_call chunk other zipper) other zipper2)
         mapper)
  in
  let lowered = fuse_expr expr in
  Alcotest.(check string)
    "builtin" "blorp_vzip_parallel"
    (lowered_builtin_name lowered);
  match lowered.desc with
  | CCall (CKBuiltin _, _, [ _source; zip_other; callback ]) -> (
      Alcotest.(check bool)
        "explicit zip argument" true
        (match zip_other.desc with
        | CVar v -> Var.equal v (Var.named "other")
        | _ -> false);
      match callback.desc with
      | CLambda lam ->
          Alcotest.(check bool)
            "no indexed side-vector load" false
            (contains_intrinsic "tensor_get_unchecked" lam.lam_body)
      | _ -> Alcotest.fail "expected lowered callback lambda")
  | _ -> Alcotest.fail "expected vzip builtin shape"

let test_distinct_zip_vectors_fall_back_to_indexed_vmap () =
  let expr =
    parallel_expr
      (zip_map_call (zip_map_call chunk other zipper) other2 zipper2)
  in
  let lowered = fuse_expr expr in
  Alcotest.(check string)
    "builtin" "blorp_vmap_indexed_parallel"
    (lowered_builtin_name lowered);
  match (lowered_callback lowered).desc with
  | CLambda lam ->
      Alcotest.(check bool)
        "indexed side-vector load" true
        (contains_intrinsic "tensor_get_unchecked" lam.lam_body)
  | _ -> Alcotest.fail "expected lowered callback lambda"

let test_non_chain_body_is_left_as_vector_parallel_call () =
  let mapped = map_call chunk mapper in
  let body =
    mk mapped.ty
      (CLet
         ( {
             bind_var = Var.named "tmp";
             bind_mut = false;
             bind_ty = mapped.ty;
             bind_rhs = mapped;
           },
           cvar "tmp" mapped.ty ))
  in
  let lowered = fuse_expr (parallel_expr body) in
  match lowered.desc with
  | CCall (CKUser (_, Some id), _, _) ->
      Alcotest.(check int) "vector parallel def id" def_vector_parallel id
  | _ ->
      Alcotest.failf "expected unfused Vector.parallel call, got %s"
        (Blorp.Core.pp_to_string lowered)

let suite =
  [
    ( "fusion",
      [
        Alcotest.test_case "map_chain_lowers_to_vmap_parallel" `Quick
          test_map_chain_lowers_to_vmap_parallel;
        Alcotest.test_case "indexed_chain_lowers_to_indexed_vmap_parallel"
          `Quick test_indexed_chain_lowers_to_indexed_vmap_parallel;
        Alcotest.test_case "single_zip_chain_lowers_to_vzip_parallel" `Quick
          test_single_zip_chain_lowers_to_vzip_parallel;
        Alcotest.test_case "reused_zip_vector_lowers_to_vzip_parallel" `Quick
          test_reused_zip_vector_lowers_to_vzip_parallel;
        Alcotest.test_case "distinct_zip_vectors_fall_back_to_indexed_vmap"
          `Quick test_distinct_zip_vectors_fall_back_to_indexed_vmap;
        Alcotest.test_case "non_chain_body_is_left_as_vector_parallel_call"
          `Quick test_non_chain_body_is_left_as_vector_parallel_call;
      ] );
  ]
