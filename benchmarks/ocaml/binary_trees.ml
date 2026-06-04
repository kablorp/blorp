type tree =
  | Leaf of int
  | Node of tree * tree

let rec bottom_up_tree_with_value depth value =
  if depth <= 0 then Leaf value
  else
    let next = value * 2 in
    Node (bottom_up_tree_with_value (depth - 1) next, bottom_up_tree_with_value (depth - 1) (next + 1))

let bottom_up_tree depth = bottom_up_tree_with_value depth 1

let rec item_check tree =
  match tree with
  | Leaf value -> value
  | Node (left, right) -> 1 + item_check left + item_check right

let int_arg default =
  if Array.length Sys.argv > 1 then
    try int_of_string Sys.argv.(1) with Failure _ -> default
  else default

let () =
  let n = int_arg 15 in
  let min_depth = 4 in
  let max_depth = if min_depth + 2 > n then min_depth + 2 else n in
  let stretch_depth = max_depth + 1 in
  let stretch_tree = bottom_up_tree stretch_depth in
  Printf.printf "stretch tree of depth %d\t check: %d\n" stretch_depth (item_check stretch_tree);
  let long_lived_tree = bottom_up_tree max_depth in
  let depth = ref min_depth in
  while !depth <= max_depth do
    let iterations = 1 lsl (max_depth - !depth + min_depth) in
    let check = ref 0 in
    for _i = 1 to iterations do
      check := !check + item_check (bottom_up_tree !depth)
    done;
    Printf.printf "%d\t trees of depth %d\t check: %d\n" iterations !depth !check;
    depth := !depth + 2
  done;
  Printf.printf "long lived tree of depth %d\t check: %d\n" max_depth
    (item_check long_lived_tree)
