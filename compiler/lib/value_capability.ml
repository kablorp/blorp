(** Resource-sensitive value capability facts. *)

type target = OneShotStream | ResourceSource
type placement = Direct | OrdinaryCarrier | FunctionCarrier
type item = { target : target; placement : placement }
type t = Ordinary | Carries of item list

let ordinary = Ordinary
let item_equal a b = a.target = b.target && a.placement = b.placement

let of_items items =
  let items =
    List.fold_left
      (fun acc item ->
        if List.exists (item_equal item) acc then acc else item :: acc)
      [] items
    |> List.rev
  in
  match items with [] -> Ordinary | _ -> Carries items

let items = function Ordinary -> [] | Carries items -> items

let has target capability =
  List.exists (fun item -> item.target = target) (items capability)

let has_function_carrier target capability =
  List.exists
    (fun item ->
      item.target = target
      && match item.placement with FunctionCarrier -> true | _ -> false)
    (items capability)

let is_direct target capability =
  List.exists
    (fun item ->
      item.target = target
      && match item.placement with Direct -> true | _ -> false)
    (items capability)

let has_ordinary_carrier target capability =
  List.exists
    (fun item ->
      item.target = target
      && match item.placement with OrdinaryCarrier -> true | _ -> false)
    (items capability)
