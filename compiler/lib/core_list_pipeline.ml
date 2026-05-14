(** Explicit representation for recognized List pipelines.

    Construction is centralized here so downstream lowering can operate on a
    validated shape instead of repeatedly rediscovering whether an expression is
    a source, stage, or terminal sink. *)

let ty_int = Ast.TyNamed ("Int", [])

type source =
  | SourceList of { expr : Core.core; elem_ty : Ast.type_expr }
  | SourceRange of { start : Core.core; stop : Core.core }

type stage =
  | StageFilter of { callback : Core.core; input_ty : Ast.type_expr }
  | StageMap of {
      callback : Core.core;
      input_ty : Ast.type_expr;
      output_ty : Ast.type_expr;
    }
  | StageFilterMap of {
      callback : Core.core;
      input_ty : Ast.type_expr;
      output_ty : Ast.type_expr;
      option_ty : Ast.type_expr;
    }

type cardinality = Exact | UpperBound | Terminal

type sink =
  | SinkCollect of { result_ty : Ast.type_expr }
  | SinkFold of {
      init : Core.core;
      reducer : Core.core;
      acc_ty : Ast.type_expr;
    }
  | SinkLength

type nonempty_stages = { first : stage; rest : stage list }

type t = {
  source : source;
  stage_chain : nonempty_stages;
  sink : sink;
  cardinality : cardinality;
  result_ty : Ast.type_expr;
  loc : Ast.loc;
}

let stages plan = plan.stage_chain.first :: plan.stage_chain.rest
let source plan = plan.source
let sink plan = plan.sink
let cardinality plan = plan.cardinality
let result_ty plan = plan.result_ty
let loc plan = plan.loc
let stage_count plan = List.length (stages plan)

let list_elem_ty = function
  | Ast.TyNamed ("List", [ elem_ty ]) -> Some elem_ty
  | _ -> None

let starts_with ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

let strip_prefix ~prefix s =
  if starts_with ~prefix s then
    Some
      (String.sub s (String.length prefix)
         (String.length s - String.length prefix))
  else None

let strip_mono_suffix name =
  let marker = "__mono_" in
  let marker_len = String.length marker in
  let rec find i =
    if i + marker_len > String.length name then name
    else if String.sub name i marker_len = marker then String.sub name 0 i
    else find (i + 1)
  in
  find 0

let supported_list_base_names =
  [
    "filter";
    "filter_map";
    "map";
    "fold";
    "fold_left";
    "length";
    "range";
    "flat_map";
    "partition";
    "scan";
    "sort";
    "reverse";
    "zip";
    "zip_with";
  ]

let trait_resolved_list_length_name name =
  let prefix = "HasLength_length_List" in
  starts_with ~prefix name

let base_list_func_name name =
  let base = strip_mono_suffix name in
  let base =
    match strip_prefix ~prefix:"std_list__" base with
    | Some rest -> rest
    | None -> (
        match strip_prefix ~prefix:"__ufcs_std$list__" base with
        | Some rest -> rest
        | None -> base)
  in
  if List.exists (( = ) base) supported_list_base_names then Some base
  else if trait_resolved_list_length_name base then Some "length"
  else None

let call_base_and_args e =
  match e.Core.desc with
  | Core.CCall (Core.CKUser (name, _), _, args) ->
      Option.map (fun base -> (base, args)) (base_list_func_name name)
  | Core.CCall (Core.CKUnknown, { Core.desc = Core.CVar v; _ }, args) ->
      Option.map (fun base -> (base, args)) (base_list_func_name v.Core.vname)
  | _ -> None

let update_cardinality cardinality stage =
  match stage with
  | StageMap _ -> cardinality
  | StageFilterMap _ | StageFilter _ -> (
      match cardinality with
      | Exact | UpperBound -> UpperBound
      | Terminal -> Terminal)

type collected = {
  collected_source : source;
  collected_stages : stage list;
  collected_cardinality : cardinality;
  collected_elem_ty : Ast.type_expr;
}

let append_stage collected stage output_ty =
  {
    collected_source = collected.collected_source;
    collected_stages = collected.collected_stages @ [ stage ];
    collected_cardinality =
      update_cardinality collected.collected_cardinality stage;
    collected_elem_ty = output_ty;
  }

let rec collect e =
  match call_base_and_args e with
  | Some ("range", [ start; stop ]) ->
      Some
        {
          collected_source = SourceRange { start; stop };
          collected_stages = [];
          collected_cardinality = Exact;
          collected_elem_ty = ty_int;
        }
  | Some ("filter", [ source; callback ]) -> (
      match collect source with
      | Some collected ->
          let stage =
            StageFilter { callback; input_ty = collected.collected_elem_ty }
          in
          Some (append_stage collected stage collected.collected_elem_ty)
      | None -> None)
  | Some ("filter_map", [ source; callback ]) -> (
      match (collect source, list_elem_ty e.Core.ty) with
      | Some collected, Some output_ty ->
          let option_ty = Ast.TyNamed ("Option", [ output_ty ]) in
          let stage =
            StageFilterMap
              {
                callback;
                input_ty = collected.collected_elem_ty;
                output_ty;
                option_ty;
              }
          in
          Some (append_stage collected stage output_ty)
      | _ -> None)
  | Some ("map", [ source; callback ]) -> (
      match (collect source, list_elem_ty e.Core.ty) with
      | Some collected, Some output_ty ->
          let stage =
            StageMap
              { callback; input_ty = collected.collected_elem_ty; output_ty }
          in
          Some (append_stage collected stage output_ty)
      | _ -> None)
  | _ -> (
      match list_elem_ty e.Core.ty with
      | Some elem_ty ->
          Some
            {
              collected_source = SourceList { expr = e; elem_ty };
              collected_stages = [];
              collected_cardinality = Exact;
              collected_elem_ty = elem_ty;
            }
      | None -> None)

let nonempty stages =
  match stages with first :: rest -> Some { first; rest } | [] -> None

let make_plan ~source ~stages ~sink ~cardinality ~result_ty ~loc =
  match nonempty stages with
  | Some stage_chain ->
      Some { source; stage_chain; sink; cardinality; result_ty; loc }
  | None -> None

let plan_of_expr e =
  match call_base_and_args e with
  | Some (("fold" | "fold_left"), [ source; init; reducer ]) -> (
      match collect source with
      | Some collected ->
          make_plan ~source:collected.collected_source
            ~stages:collected.collected_stages
            ~sink:(SinkFold { init; reducer; acc_ty = e.Core.ty })
            ~cardinality:Terminal ~result_ty:e.Core.ty ~loc:e.Core.loc
      | None -> None)
  | Some ("length", [ source ]) -> (
      match collect source with
      | Some collected ->
          make_plan ~source:collected.collected_source
            ~stages:collected.collected_stages ~sink:SinkLength
            ~cardinality:Terminal ~result_ty:e.Core.ty ~loc:e.Core.loc
      | None -> None)
  | _ -> (
      match collect e with
      | Some collected ->
          make_plan ~source:collected.collected_source
            ~stages:collected.collected_stages
            ~sink:(SinkCollect { result_ty = e.Core.ty })
            ~cardinality:collected.collected_cardinality ~result_ty:e.Core.ty
            ~loc:e.Core.loc
      | None -> None)

let describe_cardinality = function
  | Exact -> "exact"
  | UpperBound -> "upper-bound"
  | Terminal -> "terminal"

let describe_source = function
  | SourceList _ -> "list"
  | SourceRange _ -> "range"

let describe_stage = function
  | StageFilter _ -> "filter"
  | StageMap _ -> "map"
  | StageFilterMap _ -> "filter_map"

let describe_sink = function
  | SinkCollect _ -> "collect"
  | SinkFold _ -> "fold"
  | SinkLength -> "length"

let describe_plan plan =
  Printf.sprintf "%s -> [%s] -> %s (%s)"
    (describe_source plan.source)
    (String.concat ", " (List.map describe_stage (stages plan)))
    (describe_sink plan.sink)
    (describe_cardinality plan.cardinality)
