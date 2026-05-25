(** ParallelVector and ParallelMatrix pipeline recognition.

    This pass runs in the shared Fusion stage, after call resolution and before
    specialization. It recognizes scoped [Vector.parallel] and
    [Matrix.parallel] callbacks that are a straight chain of scoped [map],
    [map_indexed], and [zip_map], then lowers the chain to one runtime parallel
    call with a composed callback. Unsupported callback bodies are left
    unchanged so the std wrapper/runtime fallback remains the correctness path.
*)

open Core

type std_call =
  | VectorParallel
  | ParallelVectorMap
  | ParallelVectorMapIndexed
  | ParallelVectorZipMap
  | MatrixParallel
  | ParallelMatrixMap
  | ParallelMatrixMapIndexed
  | ParallelMatrixZipMap

type stage_kind =
  | Map of { callback : core }
  | MapIndexed of { callback : core }
  | ZipMap of { other : core; other_elem_ty : Ast.type_expr; callback : core }

type stage = { stage_kind : stage_kind; stage_output_ty : Ast.type_expr }

type plan = {
  plan_source : core;
  plan_source_elem_ty : Ast.type_expr;
  plan_dim : Ast.type_expr;
  plan_stages : stage list;
  plan_result_ty : Ast.type_expr;
  plan_result_elem_ty : Ast.type_expr;
  plan_loc : Ast.loc;
}

type zip_runtime_plan = { zip_other : core; zip_elem_ty : Ast.type_expr }

type matrix_plan = {
  matrix_plan_source : core;
  matrix_plan_source_elem_ty : Ast.type_expr;
  matrix_plan_rows : Ast.type_expr;
  matrix_plan_cols : Ast.type_expr;
  matrix_plan_stages : stage list;
  matrix_plan_result_ty : Ast.type_expr;
  matrix_plan_result_elem_ty : Ast.type_expr;
  matrix_plan_loc : Ast.loc;
}

let ty_int = Ast.TyNamed ("Int", [])
let ty_void = Ast.TyNamed ("Void", [])
let mk ?(loc = Ast.dummy_loc) ty desc = { desc; ty; loc }
let void ?(loc = Ast.dummy_loc) () = mk ~loc ty_void CVoid
let var ?(loc = Ast.dummy_loc) v ty = mk ~loc ty (CVar v)

let closure_call ?(loc = Ast.dummy_loc) fn args ty =
  mk ~loc ty (CCall (CKClosure, fn, args))

let builtin_call ?(loc = Ast.dummy_loc) name args ty =
  mk ~loc ty (CCall (CKBuiltin name, void ~loc (), args))

let intrinsic_call ?(loc = Ast.dummy_loc) name args ty =
  mk ~loc ty (CCall (CKIntrinsic name, void ~loc (), args))

let starts_with s prefix =
  let slen = String.length s in
  let plen = String.length prefix in
  slen >= plen && String.sub s 0 plen = prefix

let ends_with s suffix =
  let slen = String.length s in
  let suffix_len = String.length suffix in
  slen >= suffix_len && String.sub s (slen - suffix_len) suffix_len = suffix

let strip_mono_suffix name =
  let marker = "__mono_" in
  let marker_len = String.length marker in
  let rec find i =
    if i + marker_len > String.length name then name
    else if String.sub name i marker_len = marker then String.sub name 0 i
    else find (i + 1)
  in
  find 0

let source_name (f : core_func) =
  let name = strip_mono_suffix f.cf_name in
  let name =
    match f.cf_module with
    | None -> name
    | Some module_path ->
        let prefix = Codegen_names.sanitize_module_name module_path ^ "__" in
        if starts_with name prefix then
          String.sub name (String.length prefix)
            (String.length name - String.length prefix)
        else name
  in
  let pure_suffix = "__pure" in
  if ends_with name pure_suffix then
    String.sub name 0 (String.length name - String.length pure_suffix)
  else name

let classify_std_func (f : core_func) =
  match (f.cf_module, source_name f) with
  | Some "std/vector", "parallel" -> Some VectorParallel
  | Some "std/parallel_vector", "map" -> Some ParallelVectorMap
  | Some "std/parallel_vector", "map_indexed" -> Some ParallelVectorMapIndexed
  | Some "std/parallel_vector", "zip_map" -> Some ParallelVectorZipMap
  | Some "std/matrix", "parallel" -> Some MatrixParallel
  | Some "std/parallel_matrix", "map" -> Some ParallelMatrixMap
  | Some "std/parallel_matrix", "map_indexed" -> Some ParallelMatrixMapIndexed
  | Some "std/parallel_matrix", "zip_map" -> Some ParallelMatrixZipMap
  | _ -> None

let collect_std_calls (prog : core_program) =
  let calls = Hashtbl.create 16 in
  let remember_func f =
    match classify_std_func f with
    | Some kind -> Hashtbl.replace calls f.cf_def_id kind
    | None -> ()
  in
  let rec visit_decl d =
    match d.cd_desc with
    | CDFunc f -> remember_func f
    | CDPrivate inner -> visit_decl inner
    | _ -> ()
  in
  List.iter visit_decl prog;
  calls

let std_call_kind calls def_id = Hashtbl.find_opt calls def_id

let vector_elem_dim ty =
  match Codegen_types.normalize_type ty with
  | Ast.TyArray (elem_ty, [ dim ]) -> Some (elem_ty, dim)
  | _ -> None

let parallel_vector_elem_dim ty =
  match Codegen_types.normalize_type ty with
  | Ast.TyNamed ("ParallelVector", [ elem_ty; dim ]) -> Some (elem_ty, dim)
  | _ -> None

let matrix_elem_dims ty =
  match Codegen_types.normalize_type ty with
  | Ast.TyArray (elem_ty, [ rows; cols ]) -> Some (elem_ty, rows, cols)
  | _ -> None

let parallel_matrix_elem_dims ty =
  match Codegen_types.normalize_type ty with
  | Ast.TyNamed ("ParallelMatrix", [ elem_ty; rows; cols ]) ->
      Some (elem_ty, rows, cols)
  | _ -> None

let dims_equal a b = a = b

let stage_output_elem_dim expr =
  match parallel_vector_elem_dim expr.ty with
  | Some (elem_ty, dim) -> Some (elem_ty, dim)
  | None -> vector_elem_dim expr.ty

let stage_output_elem_dims expr =
  match parallel_matrix_elem_dims expr.ty with
  | Some (elem_ty, rows, cols) -> Some (elem_ty, rows, cols)
  | None -> matrix_elem_dims expr.ty

let rec stages_of_expr calls chunk_var dim expr =
  match expr.desc with
  | CVar v when Var.equal v chunk_var -> Some []
  | CCall (CKUser (_, Some def_id), _, [ input; callback ]) -> (
      match std_call_kind calls def_id with
      | Some ParallelVectorMap -> (
          match
            ( stages_of_expr calls chunk_var dim input,
              stage_output_elem_dim expr )
          with
          | Some stages, Some (output_ty, output_dim)
            when dims_equal dim output_dim ->
              Some
                (stages
                @ [
                    {
                      stage_kind = Map { callback };
                      stage_output_ty = output_ty;
                    };
                  ])
          | _ -> None)
      | Some ParallelVectorMapIndexed -> (
          match
            ( stages_of_expr calls chunk_var dim input,
              stage_output_elem_dim expr )
          with
          | Some stages, Some (output_ty, output_dim)
            when dims_equal dim output_dim ->
              Some
                (stages
                @ [
                    {
                      stage_kind = MapIndexed { callback };
                      stage_output_ty = output_ty;
                    };
                  ])
          | _ -> None)
      | _ -> None)
  | CCall (CKUser (_, Some def_id), _, [ input; other; callback ]) -> (
      match std_call_kind calls def_id with
      | Some ParallelVectorZipMap -> (
          match
            ( stages_of_expr calls chunk_var dim input,
              stage_output_elem_dim expr,
              vector_elem_dim other.ty )
          with
          | ( Some stages,
              Some (output_ty, output_dim),
              Some (other_elem_ty, other_dim) )
            when dims_equal dim output_dim && dims_equal dim other_dim ->
              Some
                (stages
                @ [
                    {
                      stage_kind = ZipMap { other; other_elem_ty; callback };
                      stage_output_ty = output_ty;
                    };
                  ])
          | _ -> None)
      | _ -> None)
  | _ -> None

let rec matrix_stages_of_expr calls chunk_var rows cols expr =
  match expr.desc with
  | CVar v when Var.equal v chunk_var -> Some []
  | CCall (CKUser (_, Some def_id), _, [ input; callback ]) -> (
      match std_call_kind calls def_id with
      | Some ParallelMatrixMap -> (
          match
            ( matrix_stages_of_expr calls chunk_var rows cols input,
              stage_output_elem_dims expr )
          with
          | Some stages, Some (output_ty, output_rows, output_cols)
            when dims_equal rows output_rows && dims_equal cols output_cols ->
              Some
                (stages
                @ [
                    {
                      stage_kind = Map { callback };
                      stage_output_ty = output_ty;
                    };
                  ])
          | _ -> None)
      | Some ParallelMatrixMapIndexed -> (
          match
            ( matrix_stages_of_expr calls chunk_var rows cols input,
              stage_output_elem_dims expr )
          with
          | Some stages, Some (output_ty, output_rows, output_cols)
            when dims_equal rows output_rows && dims_equal cols output_cols ->
              Some
                (stages
                @ [
                    {
                      stage_kind = MapIndexed { callback };
                      stage_output_ty = output_ty;
                    };
                  ])
          | _ -> None)
      | _ -> None)
  | CCall (CKUser (_, Some def_id), _, [ input; other; callback ]) -> (
      match std_call_kind calls def_id with
      | Some ParallelMatrixZipMap -> (
          match
            ( matrix_stages_of_expr calls chunk_var rows cols input,
              stage_output_elem_dims expr,
              matrix_elem_dims other.ty )
          with
          | ( Some stages,
              Some (output_ty, output_rows, output_cols),
              Some (other_elem_ty, other_rows, other_cols) )
            when dims_equal rows output_rows
                 && dims_equal cols output_cols
                 && dims_equal rows other_rows && dims_equal cols other_cols ->
              Some
                (stages
                @ [
                    {
                      stage_kind = ZipMap { other; other_elem_ty; callback };
                      stage_output_ty = output_ty;
                    };
                  ])
          | _ -> None)
      | _ -> None)
  | _ -> None

let plan_of_vector_parallel calls source body result_ty loc =
  match (vector_elem_dim source.ty, body.desc, vector_elem_dim result_ty) with
  | Some (source_elem_ty, dim), CLambda lam, Some (result_elem_ty, result_dim)
    when dims_equal dim result_dim -> (
      match lam.lam_params with
      | [ (chunk_var, chunk_ty) ] -> (
          match parallel_vector_elem_dim chunk_ty with
          | Some (_, chunk_dim) when dims_equal dim chunk_dim -> (
              match stages_of_expr calls chunk_var dim lam.lam_body with
              | Some (_ :: _ as stages) ->
                  Some
                    {
                      plan_source = source;
                      plan_source_elem_ty = source_elem_ty;
                      plan_dim = dim;
                      plan_stages = stages;
                      plan_result_ty = result_ty;
                      plan_result_elem_ty = result_elem_ty;
                      plan_loc = loc;
                    }
              | _ -> None)
          | _ -> None)
      | _ -> None)
  | _ -> None

let plan_of_matrix_parallel calls source body result_ty loc =
  match (matrix_elem_dims source.ty, body.desc, matrix_elem_dims result_ty) with
  | ( Some (source_elem_ty, rows, cols),
      CLambda lam,
      Some (result_elem_ty, result_rows, result_cols) )
    when dims_equal rows result_rows && dims_equal cols result_cols -> (
      match lam.lam_params with
      | [ (chunk_var, chunk_ty) ] -> (
          match parallel_matrix_elem_dims chunk_ty with
          | Some (_, chunk_rows, chunk_cols)
            when dims_equal rows chunk_rows && dims_equal cols chunk_cols -> (
              match
                matrix_stages_of_expr calls chunk_var rows cols lam.lam_body
              with
              | Some (_ :: _ as stages) ->
                  Some
                    {
                      matrix_plan_source = source;
                      matrix_plan_source_elem_ty = source_elem_ty;
                      matrix_plan_rows = rows;
                      matrix_plan_cols = cols;
                      matrix_plan_stages = stages;
                      matrix_plan_result_ty = result_ty;
                      matrix_plan_result_elem_ty = result_elem_ty;
                      matrix_plan_loc = loc;
                    }
              | _ -> None)
          | _ -> None)
      | _ -> None)
  | _ -> None

let stages_need_index stages =
  List.exists
    (fun stage ->
      match stage.stage_kind with
      | Map _ -> false
      | MapIndexed _ | ZipMap _ -> true)
    stages

let plan_needs_index plan = stages_need_index plan.plan_stages

let stages_have_indexed_map stages =
  List.exists
    (fun stage ->
      match stage.stage_kind with
      | MapIndexed _ -> true
      | Map _ | ZipMap _ -> false)
    stages

let stages_have_zip stages =
  List.exists
    (fun stage ->
      match stage.stage_kind with
      | ZipMap _ -> true
      | Map _ | MapIndexed _ -> false)
    stages

let same_zip_other a b =
  match (a.desc, b.desc) with CVar av, CVar bv -> Var.equal av bv | _ -> a = b

let zip_runtime_for_stages ~allow_index stages =
  let rec loop selected = function
    | [] -> selected
    | stage :: rest -> (
        match stage.stage_kind with
        | Map _ -> loop selected rest
        | MapIndexed _ -> if allow_index then loop selected rest else None
        | ZipMap { other; other_elem_ty; _ } -> (
            match selected with
            | None ->
                loop
                  (Some { zip_other = other; zip_elem_ty = other_elem_ty })
                  rest
            | Some zip
              when same_zip_other zip.zip_other other
                   && zip.zip_elem_ty = other_elem_ty ->
                loop selected rest
            | Some _ -> None))
  in
  loop None stages

let plan_zip_runtime plan =
  zip_runtime_for_stages ~allow_index:false plan.plan_stages

let counter = ref 0

let fresh prefix =
  let n = !counter in
  incr counter;
  Printf.sprintf "__pv_%s_%d" prefix n

let bind_let ~loc name ty rhs body =
  mk ~loc body.ty
    (CLet
       ( {
           bind_var = Var.named name;
           bind_mut = false;
           bind_ty = ty;
           bind_rhs = rhs;
         },
         body ))

let apply_stage ~loc index zip_value current stage =
  match stage.stage_kind with
  | Map { callback } ->
      closure_call ~loc callback [ current ] stage.stage_output_ty
  | MapIndexed { callback } -> (
      match index with
      | Some index ->
          closure_call ~loc callback [ index; current ] stage.stage_output_ty
      | None -> current)
  | ZipMap { other; other_elem_ty; callback } -> (
      match zip_value with
      | Some other_elem ->
          closure_call ~loc callback [ current; other_elem ]
            stage.stage_output_ty
      | None -> (
          match index with
          | Some index ->
              let other_elem =
                intrinsic_call ~loc "tensor_get_unchecked" [ other; index ]
                  other_elem_ty
              in
              closure_call ~loc callback [ current; other_elem ]
                stage.stage_output_ty
          | None -> current))

let rec build_callback_body ~loc ~index ~zip_value current = function
  | [] -> current
  | [ stage ] -> apply_stage ~loc index zip_value current stage
  | stage :: rest ->
      let rhs = apply_stage ~loc index zip_value current stage in
      let name = fresh "stage" in
      let current = var ~loc (Var.named name) rhs.ty in
      bind_let ~loc name rhs.ty rhs
        (build_callback_body ~loc ~index ~zip_value current rest)

let callback_type params return_ty =
  Ast.TyFunc { params; return = return_ty; is_pure = true }

let lower_plan plan =
  let loc = plan.plan_loc in
  let value_var = Var.named (fresh "value") in
  let value = var ~loc value_var plan.plan_source_elem_ty in
  match plan_zip_runtime plan with
  | Some zip ->
      let zip_var = Var.named (fresh "zip") in
      let zip_value = var ~loc zip_var zip.zip_elem_ty in
      let body =
        build_callback_body ~loc ~index:None ~zip_value:(Some zip_value) value
          plan.plan_stages
      in
      let callback =
        mk ~loc
          (callback_type
             [ plan.plan_source_elem_ty; zip.zip_elem_ty ]
             plan.plan_result_elem_ty)
          (CLambda
             {
               lam_params =
                 [
                   (value_var, plan.plan_source_elem_ty);
                   (zip_var, zip.zip_elem_ty);
                 ];
               lam_body = body;
               lam_return_ty = plan.plan_result_elem_ty;
               lam_is_pure = true;
             })
      in
      builtin_call ~loc "blorp_vzip_parallel"
        [ plan.plan_source; zip.zip_other; callback ]
        plan.plan_result_ty
  | None when plan_needs_index plan ->
      let index_var = Var.named (fresh "index") in
      let index_ty = Ast.TyRange plan.plan_dim in
      let index = var ~loc index_var index_ty in
      let body =
        build_callback_body ~loc ~index:(Some index) ~zip_value:None value
          plan.plan_stages
      in
      let callback =
        mk ~loc
          (callback_type
             [ index_ty; plan.plan_source_elem_ty ]
             plan.plan_result_elem_ty)
          (CLambda
             {
               lam_params =
                 [
                   (index_var, index_ty); (value_var, plan.plan_source_elem_ty);
                 ];
               lam_body = body;
               lam_return_ty = plan.plan_result_elem_ty;
               lam_is_pure = true;
             })
      in
      builtin_call ~loc "blorp_vmap_indexed_parallel"
        [ plan.plan_source; callback ]
        plan.plan_result_ty
  | None ->
      let body =
        build_callback_body ~loc ~index:None ~zip_value:None value
          plan.plan_stages
      in
      let callback =
        mk ~loc
          (callback_type [ plan.plan_source_elem_ty ] plan.plan_result_elem_ty)
          (CLambda
             {
               lam_params = [ (value_var, plan.plan_source_elem_ty) ];
               lam_body = body;
               lam_return_ty = plan.plan_result_elem_ty;
               lam_is_pure = true;
             })
      in
      builtin_call ~loc "blorp_vmap_parallel"
        [ plan.plan_source; callback ]
        plan.plan_result_ty

let apply_matrix_stage ~loc row col flat_index zip_value current stage =
  match stage.stage_kind with
  | Map { callback } ->
      closure_call ~loc callback [ current ] stage.stage_output_ty
  | MapIndexed { callback } ->
      closure_call ~loc callback [ row; col; current ] stage.stage_output_ty
  | ZipMap { other; other_elem_ty; callback } -> (
      match zip_value with
      | Some other_elem ->
          closure_call ~loc callback [ current; other_elem ]
            stage.stage_output_ty
      | None -> (
          match flat_index with
          | Some index ->
              let other_elem =
                intrinsic_call ~loc "tensor_get_unchecked" [ other; index ]
                  other_elem_ty
              in
              closure_call ~loc callback [ current; other_elem ]
                stage.stage_output_ty
          | None -> current))

let rec build_matrix_callback_body ~loc ~row ~col ~flat_index ~zip_value current
    = function
  | [] -> current
  | [ stage ] ->
      apply_matrix_stage ~loc row col flat_index zip_value current stage
  | stage :: rest ->
      let rhs =
        apply_matrix_stage ~loc row col flat_index zip_value current stage
      in
      let name = fresh "mstage" in
      let current = var ~loc (Var.named name) rhs.ty in
      bind_let ~loc name rhs.ty rhs
        (build_matrix_callback_body ~loc ~row ~col ~flat_index ~zip_value
           current rest)

let lower_matrix_plan plan =
  let loc = plan.matrix_plan_loc in
  let value_var = Var.named (fresh "mvalue") in
  let value = var ~loc value_var plan.matrix_plan_source_elem_ty in
  match zip_runtime_for_stages ~allow_index:true plan.matrix_plan_stages with
  | Some zip when stages_have_indexed_map plan.matrix_plan_stages ->
      let row_var = Var.named (fresh "row") in
      let col_var = Var.named (fresh "col") in
      let zip_var = Var.named (fresh "mzip") in
      let row_ty = Ast.TyRange plan.matrix_plan_rows in
      let col_ty = Ast.TyRange plan.matrix_plan_cols in
      let row = var ~loc row_var row_ty in
      let col = var ~loc col_var col_ty in
      let zip_value = var ~loc zip_var zip.zip_elem_ty in
      let body =
        build_matrix_callback_body ~loc ~row ~col ~flat_index:None
          ~zip_value:(Some zip_value) value plan.matrix_plan_stages
      in
      let callback =
        mk ~loc
          (callback_type
             [
               row_ty; col_ty; plan.matrix_plan_source_elem_ty; zip.zip_elem_ty;
             ]
             plan.matrix_plan_result_elem_ty)
          (CLambda
             {
               lam_params =
                 [
                   (row_var, row_ty);
                   (col_var, col_ty);
                   (value_var, plan.matrix_plan_source_elem_ty);
                   (zip_var, zip.zip_elem_ty);
                 ];
               lam_body = body;
               lam_return_ty = plan.matrix_plan_result_elem_ty;
               lam_is_pure = true;
             })
      in
      Some
        (builtin_call ~loc "blorp_mzip_indexed_parallel"
           [ plan.matrix_plan_source; zip.zip_other; callback ]
           plan.matrix_plan_result_ty)
  | Some zip ->
      let zip_var = Var.named (fresh "mzip") in
      let zip_value = var ~loc zip_var zip.zip_elem_ty in
      let body =
        build_callback_body ~loc ~index:None ~zip_value:(Some zip_value) value
          plan.matrix_plan_stages
      in
      let callback =
        mk ~loc
          (callback_type
             [ plan.matrix_plan_source_elem_ty; zip.zip_elem_ty ]
             plan.matrix_plan_result_elem_ty)
          (CLambda
             {
               lam_params =
                 [
                   (value_var, plan.matrix_plan_source_elem_ty);
                   (zip_var, zip.zip_elem_ty);
                 ];
               lam_body = body;
               lam_return_ty = plan.matrix_plan_result_elem_ty;
               lam_is_pure = true;
             })
      in
      Some
        (builtin_call ~loc "blorp_mzip_parallel"
           [ plan.matrix_plan_source; zip.zip_other; callback ]
           plan.matrix_plan_result_ty)
  | None when stages_have_zip plan.matrix_plan_stages ->
      let row_var = Var.named (fresh "row") in
      let col_var = Var.named (fresh "col") in
      let flat_var = Var.named (fresh "flat") in
      let row_ty = Ast.TyRange plan.matrix_plan_rows in
      let col_ty = Ast.TyRange plan.matrix_plan_cols in
      let row = var ~loc row_var row_ty in
      let col = var ~loc col_var col_ty in
      let flat_index = var ~loc flat_var ty_int in
      let body =
        build_matrix_callback_body ~loc ~row ~col ~flat_index:(Some flat_index)
          ~zip_value:None value plan.matrix_plan_stages
      in
      let callback =
        mk ~loc
          (callback_type
             [ row_ty; col_ty; ty_int; plan.matrix_plan_source_elem_ty ]
             plan.matrix_plan_result_elem_ty)
          (CLambda
             {
               lam_params =
                 [
                   (row_var, row_ty);
                   (col_var, col_ty);
                   (flat_var, ty_int);
                   (value_var, plan.matrix_plan_source_elem_ty);
                 ];
               lam_body = body;
               lam_return_ty = plan.matrix_plan_result_elem_ty;
               lam_is_pure = true;
             })
      in
      Some
        (builtin_call ~loc "blorp_mmap_flat_indexed_parallel"
           [ plan.matrix_plan_source; callback ]
           plan.matrix_plan_result_ty)
  | None when stages_need_index plan.matrix_plan_stages ->
      let row_var = Var.named (fresh "row") in
      let col_var = Var.named (fresh "col") in
      let row_ty = Ast.TyRange plan.matrix_plan_rows in
      let col_ty = Ast.TyRange plan.matrix_plan_cols in
      let row = var ~loc row_var row_ty in
      let col = var ~loc col_var col_ty in
      let body =
        build_matrix_callback_body ~loc ~row ~col ~flat_index:None
          ~zip_value:None value plan.matrix_plan_stages
      in
      let callback =
        mk ~loc
          (callback_type
             [ row_ty; col_ty; plan.matrix_plan_source_elem_ty ]
             plan.matrix_plan_result_elem_ty)
          (CLambda
             {
               lam_params =
                 [
                   (row_var, row_ty);
                   (col_var, col_ty);
                   (value_var, plan.matrix_plan_source_elem_ty);
                 ];
               lam_body = body;
               lam_return_ty = plan.matrix_plan_result_elem_ty;
               lam_is_pure = true;
             })
      in
      Some
        (builtin_call ~loc "blorp_mmap_indexed_parallel"
           [ plan.matrix_plan_source; callback ]
           plan.matrix_plan_result_ty)
  | None ->
      let body =
        build_callback_body ~loc ~index:None ~zip_value:None value
          plan.matrix_plan_stages
      in
      let callback =
        mk ~loc
          (callback_type
             [ plan.matrix_plan_source_elem_ty ]
             plan.matrix_plan_result_elem_ty)
          (CLambda
             {
               lam_params = [ (value_var, plan.matrix_plan_source_elem_ty) ];
               lam_body = body;
               lam_return_ty = plan.matrix_plan_result_elem_ty;
               lam_is_pure = true;
             })
      in
      Some
        (builtin_call ~loc "blorp_mmap_parallel"
           [ plan.matrix_plan_source; callback ]
           plan.matrix_plan_result_ty)

let rewrite_expr calls expr =
  let rec rewrite e =
    match e.desc with
    | CCall ((CKUser (_, Some def_id) as kind), callee, [ source; body ])
      when std_call_kind calls def_id = Some VectorParallel -> (
        let source = rewrite source in
        match plan_of_vector_parallel calls source body e.ty e.loc with
        | Some plan -> rewrite (lower_plan plan)
        | None ->
            let body = rewrite body in
            { e with desc = CCall (kind, callee, [ source; body ]) })
    | CCall ((CKUser (_, Some def_id) as kind), callee, [ source; body ])
      when std_call_kind calls def_id = Some MatrixParallel -> (
        let source = rewrite source in
        match plan_of_matrix_parallel calls source body e.ty e.loc with
        | Some plan -> (
            match lower_matrix_plan plan with
            | Some lowered -> rewrite lowered
            | None ->
                let body = rewrite body in
                { e with desc = CCall (kind, callee, [ source; body ]) })
        | None ->
            let body = rewrite body in
            { e with desc = CCall (kind, callee, [ source; body ]) })
    | _ ->
        let e = map_children rewrite e in
        e
  in
  rewrite expr

let rewrite_func calls f =
  { f with cf_body = Option.map (rewrite_expr calls) f.cf_body }

let rec rewrite_decl calls d =
  let desc =
    match d.cd_desc with
    | CDFunc f -> CDFunc (rewrite_func calls f)
    | CDVar v -> CDVar { v with cv_init = rewrite_expr calls v.cv_init }
    | CDImpl impl ->
        CDImpl
          {
            impl with
            ci_methods = List.map (rewrite_func calls) impl.ci_methods;
          }
    | CDPrivate inner -> CDPrivate (rewrite_decl calls inner)
    | CDTrait _ | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _ ->
        d.cd_desc
  in
  { d with cd_desc = desc }

let fuse_program ~reg:_ prog =
  counter := 0;
  let calls = collect_std_calls prog in
  if Hashtbl.length calls = 0 then prog else List.map (rewrite_decl calls) prog
