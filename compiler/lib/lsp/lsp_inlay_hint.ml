(** Inlay hint provider for editor-only source annotations. *)

open Ast
open Lsp_json

type hint = { position : Lsp_protocol.position; label : string; kind : int }

let type_hint_kind = 1

let loc_matches_file ?file loc =
  match file with None -> true | Some expected -> loc.loc_file = Some expected

let loc_same_start a b = a.line = b.line && a.column = b.column

let decls_compatible source_decl typed_decl =
  match (source_decl.decl_desc, typed_decl.decl_desc) with
  | DFunc _, DFunc _
  | DVar _, DVar _
  | DType _, DType _
  | DRecord _, DRecord _
  | DImport _, DImport _
  | DTrait _, DTrait _
  | DImpl _, DImpl _
  | DTypeAlias _, DTypeAlias _
  | DPrivate _, DPrivate _ ->
      true
  | _ -> false

let position_after_name loc name =
  let start = Lsp_protocol.loc_to_position loc in
  { start with character = start.character + String.length name }

let hint_json hint =
  Object
    [
      ("position", Lsp_protocol.position_to_json hint.position);
      ("label", String hint.label);
      ("kind", Int hint.kind);
      ("paddingRight", Bool true);
    ]

let position_compare (a : Lsp_protocol.position) (b : Lsp_protocol.position) =
  match compare a.line b.line with
  | 0 -> compare a.character b.character
  | c -> c

let position_in_range position (range : Lsp_protocol.range option) =
  match range with
  | None -> true
  | Some range ->
      position_compare range.start position <= 0
      && position_compare position range.end_ <= 0

let range_of_json json =
  match (get "start" json, get "end" json) with
  | Some start_json, Some end_json -> (
      match
        ( Lsp_protocol.position_of_json start_json,
          Lsp_protocol.position_of_json end_json )
      with
      | Some start, Some end_ -> Some { Lsp_protocol.start; end_ }
      | _ -> None)
  | _ -> None

let request_range params = Option.bind (get "range" params) range_of_json

let maybe_add_local_type_hint hints ?file source_expr typed_expr =
  match (source_expr.expr_desc, typed_expr.expr_desc) with
  | EAssign (name, _), EVarDecl (_, Some binding_ty, _, _)
  | EVarDecl (name, None, _, _), EVarDecl (_, Some binding_ty, _, _)
    when loc_matches_file ?file source_expr.expr_loc ->
      hints :=
        {
          position = position_after_name source_expr.expr_loc name;
          label = ": " ^ Types.type_to_string binding_ty;
          kind = type_hint_kind;
        }
        :: !hints
  | _ -> ()

let rec collect_expr hints ?file source_expr typed_expr =
  maybe_add_local_type_hint hints ?file source_expr typed_expr;
  match (source_expr.expr_desc, typed_expr.expr_desc) with
  | ELambda source_func, ELambda typed_func
  | EFuncDecl source_func, EFuncDecl typed_func ->
      collect_func hints ?file source_func typed_func
  | ( EMatch (source_scrutinee, source_cases),
      EMatch (typed_scrutinee, typed_cases) ) ->
      collect_expr hints ?file source_scrutinee typed_scrutinee;
      List.iter2
        (fun source_case typed_case ->
          collect_expr hints ?file source_case.case_body typed_case.case_body)
        source_cases typed_cases
  | ESelect source_arms, ESelect typed_arms ->
      List.iter2 (collect_select_arm hints ?file) source_arms typed_arms
  | _ ->
      let source_children = Ast.expr_children source_expr in
      let typed_children = Ast.expr_children typed_expr in
      if List.length source_children = List.length typed_children then
        List.iter2 (collect_expr hints ?file) source_children typed_children

and collect_select_arm hints ?file source_arm typed_arm =
  (match (source_arm.select_arm_kind, typed_arm.select_arm_kind) with
  | ( SelectRecv { select_channel = source_channel; _ },
      SelectRecv { select_channel = typed_channel; _ } )
  | SelectSealed source_channel, SelectSealed typed_channel ->
      collect_expr hints ?file source_channel typed_channel
  | SelectAfter source_timeout, SelectAfter typed_timeout ->
      collect_expr hints ?file source_timeout typed_timeout
  | _ -> ());
  collect_expr hints ?file source_arm.select_arm_body typed_arm.select_arm_body

and collect_func hints ?file source_func typed_func =
  match
    ( Ast.func_body_expr_opt source_func.func_body,
      Ast.func_body_expr_opt typed_func.func_body )
  with
  | Some source_body, Some typed_body ->
      collect_expr hints ?file source_body typed_body
  | _ -> ()

let rec collect_decl hints ?file source_decl typed_decl =
  match (source_decl.decl_desc, typed_decl.decl_desc) with
  | DFunc source_func, DFunc typed_func ->
      collect_func hints ?file source_func typed_func
  | DVar source_var, DVar typed_var ->
      collect_expr hints ?file source_var.var_value typed_var.var_value
  | DPrivate source_inner, DPrivate typed_inner ->
      collect_decl hints ?file source_inner typed_inner
  | DImpl source_impl, DImpl typed_impl ->
      if
        List.length source_impl.impl_methods
        = List.length typed_impl.impl_methods
      then
        List.iter2 (collect_func hints ?file) source_impl.impl_methods
          typed_impl.impl_methods
  | _ -> ()

let decls_for_file file program =
  List.filter (fun decl -> loc_matches_file ~file decl.decl_loc) program

let find_matching_typed_decl typed_decls source_decl =
  List.find_opt
    (fun typed_decl ->
      loc_same_start source_decl.decl_loc typed_decl.decl_loc
      && decls_compatible source_decl typed_decl)
    typed_decls

let collect_program ?file source_program typed_program =
  let hints = ref [] in
  let source_decls =
    match file with
    | Some file -> decls_for_file file source_program
    | None -> source_program
  in
  let typed_decls =
    let _ = file in
    typed_program
  in
  List.iter
    (fun source_decl ->
      match find_matching_typed_decl typed_decls source_decl with
      | Some typed_decl -> collect_decl hints ?file source_decl typed_decl
      | None -> ())
    source_decls;
  List.rev !hints

let handle_inlay_hint (state : Lsp_state.state) (params : json) : json =
  match get "textDocument" params with
  | None -> Array []
  | Some td -> (
      let uri = Lsp_protocol.get_uri td in
      let file = Lsp_protocol.uri_to_path uri in
      match Lsp_state.find_document state uri with
      | None -> Array []
      | Some doc -> (
          match (doc.source_program, doc.program) with
          | Some source_program, Some typed_program ->
              let range = request_range params in
              collect_program ~file source_program typed_program
              |> List.filter (fun hint -> position_in_range hint.position range)
              |> List.map hint_json
              |> fun hints -> Array hints
          | _ -> Array []))
