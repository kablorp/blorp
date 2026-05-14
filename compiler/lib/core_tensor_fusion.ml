(** Tensor expression/update fusion.

    This pass runs in the shared [Fusion] stage, before specialization lowers
    tensor arithmetic to runtime helper calls. Keeping the recognition here lets
    us reason over typed Core operators instead of emitted C strings.

    The first supported shape is deliberately narrow:

    {[
      target = target + input * scalar
    ]}

    where [target] and [input] are Float/Float32 tensors with the same static
    shape, [input] is a stable variable reference, and [scalar] is a stable
    scalar value. Unsupported expressions are left unchanged for the normal
    tensor-arithmetic fallback. *)

open Core

type tensor_elem = Core_tensor_type.floating_scalar

type tensor_operand = {
  tensor_expr : core;
  tensor_elem : tensor_elem;
  tensor_type : Core_tensor_type.t;
}

type scalar_operand = { scalar_expr : core; scalar_elem : tensor_elem }

type add_scaled_update = {
  update_target : var;
  update_target_ty : Ast.type_expr;
  update_input : tensor_operand;
  update_scale : scalar_operand;
  update_loc : Ast.loc;
}

type fused_update = AddScaledUpdate of add_scaled_update

let tensor_operand ~reg expr =
  match Core_tensor_type.of_core ~reg expr with
  | Some tensor_type -> (
      match Core_tensor_type.floating_scalar_of_tensor tensor_type with
      | Some tensor_elem ->
          Some { tensor_expr = expr; tensor_elem; tensor_type }
      | None -> None)
  | None -> None

let stable_tensor_input ~reg expr =
  match expr.desc with CVar _ -> tensor_operand ~reg expr | _ -> None

let stable_scalar ~reg elem expr =
  match (expr.desc, Core_tensor_type.floating_scalar_of_type ~reg expr.ty) with
  | (CLit _ | CVar _), Some scalar_elem when scalar_elem = elem ->
      Some { scalar_expr = expr; scalar_elem }
  | _ -> None

let mul_tensor_scalar ~reg expr =
  match expr.desc with
  | CBin (Ast.Mul, l, r) -> (
      match stable_tensor_input ~reg l with
      | Some input -> (
          match stable_scalar ~reg input.tensor_elem r with
          | Some scale -> Some (input, scale)
          | None -> None)
      | None -> (
          match stable_tensor_input ~reg r with
          | Some input -> (
              match stable_scalar ~reg input.tensor_elem l with
              | Some scale -> Some (input, scale)
              | None -> None)
          | None -> None))
  | _ -> None

let add_scaled_update ~reg target rhs loc =
  let target_ref target_ty = { desc = CVar target; ty = target_ty; loc } in
  let target_match_type expr =
    match expr.desc with
    | CVar v when Var.equal v target -> Some expr.ty
    | _ -> None
  in
  match rhs.desc with
  | CBin (Ast.Add, l, r) -> (
      let target_ty, scaled_side =
        match target_match_type l with
        | Some target_ty -> (Some target_ty, Some r)
        | None -> (
            match target_match_type r with
            | Some target_ty -> (Some target_ty, Some l)
            | None -> (None, None))
      in
      match (target_ty, scaled_side) with
      | Some target_ty, Some scaled -> (
          match
            ( tensor_operand ~reg (target_ref target_ty),
              mul_tensor_scalar ~reg scaled )
          with
          | Some target_tensor, Some (input, scale)
            when target_tensor.tensor_elem = input.tensor_elem
                 && Core_tensor_type.same_static_shape target_tensor.tensor_type
                      input.tensor_type ->
              Some
                (AddScaledUpdate
                   {
                     update_target = target;
                     update_target_ty = target_ty;
                     update_input = input;
                     update_scale = scale;
                     update_loc = loc;
                   })
          | _ -> None)
      | _ -> None)
  | _ -> None

let builtin_for_elem = function
  | Core_tensor_type.Float64 -> "blorp_tensor_add_scaled_f64_cow"
  | Core_tensor_type.Float32 -> "blorp_tensor_add_scaled_f32_cow"

let lower_update = function
  | AddScaledUpdate u ->
      let callee =
        { desc = CVoid; ty = Ast.TyNamed ("Void", []); loc = u.update_loc }
      in
      let target_ref =
        {
          desc = CVar u.update_target;
          ty = u.update_target_ty;
          loc = u.update_loc;
        }
      in
      {
        desc =
          CCall
            ( CKBuiltin (builtin_for_elem u.update_input.tensor_elem),
              callee,
              [
                target_ref;
                u.update_input.tensor_expr;
                u.update_scale.scalar_expr;
              ] );
        ty = u.update_target_ty;
        loc = u.update_loc;
      }

let rec fuse_expr ~reg e =
  let e = map_children (fuse_expr ~reg) e in
  match e.desc with
  | CAssign (target, rhs) -> (
      match add_scaled_update ~reg target rhs e.loc with
      | Some fused -> { e with desc = CAssign (target, lower_update fused) }
      | None -> e)
  | _ -> e

let fuse_func ~reg f =
  { f with cf_body = Option.map (fuse_expr ~reg) f.cf_body }

let rec fuse_decl ~reg d =
  let desc =
    match d.cd_desc with
    | CDFunc f -> CDFunc (fuse_func ~reg f)
    | CDVar v -> CDVar { v with cv_init = fuse_expr ~reg v.cv_init }
    | CDImpl impl ->
        CDImpl
          { impl with ci_methods = List.map (fuse_func ~reg) impl.ci_methods }
    | CDPrivate inner -> CDPrivate (fuse_decl ~reg inner)
    | CDTrait _ | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _ ->
        d.cd_desc
  in
  { d with cd_desc = desc }

let fuse_program ~reg prog = List.map (fuse_decl ~reg) prog
