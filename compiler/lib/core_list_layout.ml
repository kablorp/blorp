(** List storage-layout classification for Core IR.

    The runtime supports two list representations: generic pointer slots and
    inline primitive/enum slots. This module is the single compiler-side place
    that maps [List[T]] to a concrete [Core.list_storage_layout] descriptor.
    Core nodes carry the result explicitly so later passes and emitters do not
    have to re-sniff element types at allocation sites. *)

open Core

let layout_of_type ?reg (list_ty : Ast.type_expr) (loc : Ast.loc) :
    list_storage_layout =
  Core_layout_type.list_storage_layout_of_type ?reg list_ty loc

let relayout_expr ~(reg : Codegen_types.registry) (e : core) : core =
  match e.desc with
  | CList lit ->
      {
        e with
        desc = CList { lit with ll_layout = layout_of_type ~reg e.ty e.loc };
      }
  | CListAlloc alloc ->
      {
        e with
        desc =
          CListAlloc { alloc with la_layout = layout_of_type ~reg e.ty e.loc };
      }
  | CListHandoff h ->
      {
        e with
        desc =
          CListHandoff
            { h with lh_layout = layout_of_type ~reg h.lh_result_ty e.loc };
      }
  | _ -> e

let annotate_expr ~(reg : Codegen_types.registry) (e : core) : core =
  Core.transform_bottom_up (relayout_expr ~reg) e

let annotate_func ~(reg : Codegen_types.registry) fn =
  { fn with cf_body = Option.map (annotate_expr ~reg) fn.cf_body }

let annotate_impl ~(reg : Codegen_types.registry) impl =
  { impl with ci_methods = List.map (annotate_func ~reg) impl.ci_methods }

let rec annotate_decl ~(reg : Codegen_types.registry) (decl : core_decl) :
    core_decl =
  let desc =
    match decl.cd_desc with
    | CDFunc fn -> CDFunc (annotate_func ~reg fn)
    | CDVar v -> CDVar { v with cv_init = annotate_expr ~reg v.cv_init }
    | CDImpl impl -> CDImpl (annotate_impl ~reg impl)
    | CDPrivate inner -> CDPrivate (annotate_decl ~reg inner)
    | (CDTrait _ | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _) as other
      ->
        other
  in
  { decl with cd_desc = desc }

let annotate_program ~(reg : Codegen_types.registry) (prog : core_program) :
    core_program =
  List.map (annotate_decl ~reg) prog
