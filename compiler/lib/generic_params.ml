type trait_ref = { tr_name : string }
type bound_type_param = { param_name : string; param_bounds : trait_ref list }

let trait_ref name = { tr_name = name }
let trait_ref_name tr = tr.tr_name
let trait_ref_names refs = List.map trait_ref_name refs

let make_bound_type_param param_name bounds =
  { param_name; param_bounds = List.map trait_ref bounds }

let to_parser_string param =
  match trait_ref_names param.param_bounds with
  | [] -> param.param_name
  | bounds -> param.param_name ^ ":" ^ String.concat "+" bounds

let param_names params = List.map (fun p -> p.param_name) params
