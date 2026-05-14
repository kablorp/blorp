(** Centralized type annotation resolution.

    This module owns the frontend boundary where parser/source type syntax is
    converted into semantic type identity. Keeping this as a named API avoids
    scattering resolver-chain knowledge across inference and typecheck. *)

open Ast

type alias_policy = ExpandAliases | PreserveAliasSource

type context = {
  env : Env.env;
  module_aliases : (string * string) list;
  alias_policy : alias_policy;
}

type resolved_type = { source : type_expr; canonical : type_expr }

let make_context ?(alias_policy = ExpandAliases) ~env ~module_aliases () =
  { env; module_aliases; alias_policy }

let resolve_qualified_names ctx ty =
  Types.resolve_qualified_types ctx.module_aliases ty

let resolve_nominal_dim_applications ctx ty =
  Env.disambiguate_nominal_dim_application ctx.env ty

let apply_alias_policy ctx ty =
  match ctx.alias_policy with
  | ExpandAliases -> Env.resolve_alias ctx.env ty
  | PreserveAliasSource -> ty

let resolve ?(qualify_owner = Fun.id) ctx source =
  let canonical =
    source
    |> resolve_qualified_names ctx
    |> qualify_owner
    |> resolve_nominal_dim_applications ctx
    |> apply_alias_policy ctx
  in
  { source; canonical }

let annotation ?qualify_owner ctx source = resolve ?qualify_owner ctx source

let annotation_canonical ?qualify_owner ctx source =
  (annotation ?qualify_owner ctx source).canonical

let value_ascription ?qualify_owner ctx source =
  resolve ?qualify_owner ctx source

let value_ascription_canonical ?qualify_owner ctx source =
  (value_ascription ?qualify_owner ctx source).canonical

let local_binding_annotation ?qualify_owner ctx source =
  resolve ?qualify_owner ctx source

let local_binding_annotation_canonical ?qualify_owner ctx source =
  (local_binding_annotation ?qualify_owner ctx source).canonical

let function_parameter_annotation ?qualify_owner ctx source =
  resolve ?qualify_owner ctx source

let function_parameter_annotation_canonical ?qualify_owner ctx source =
  (function_parameter_annotation ?qualify_owner ctx source).canonical

let function_return_annotation ?qualify_owner ctx source =
  resolve ?qualify_owner ctx source

let function_return_annotation_canonical ?qualify_owner ctx source =
  (function_return_annotation ?qualify_owner ctx source).canonical

let imported_signature ?qualify_owner ctx source =
  resolve ?qualify_owner ctx source

let imported_signature_canonical ?qualify_owner ctx source =
  (imported_signature ?qualify_owner ctx source).canonical

let record_field_type ?qualify_owner ctx source =
  resolve ?qualify_owner ctx source

let record_field_type_canonical ?qualify_owner ctx source =
  (record_field_type ?qualify_owner ctx source).canonical

let variant_field_type ?qualify_owner ctx source =
  resolve ?qualify_owner ctx source

let variant_field_type_canonical ?qualify_owner ctx source =
  (variant_field_type ?qualify_owner ctx source).canonical

let type_alias_target ?qualify_owner ctx source =
  resolve ?qualify_owner ctx source

let type_alias_target_canonical ?qualify_owner ctx source =
  (type_alias_target ?qualify_owner ctx source).canonical

let source resolved = resolved.source
let canonical resolved = resolved.canonical
