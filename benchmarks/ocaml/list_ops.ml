let make_shuffled n =
  List.init n (fun i -> ((i * 1_103_515_245) + 12_345) mod n)

let bench_append n iters =
  let checksum = ref 0 in
  for _iter = 0 to iters - 1 do
    let list = ref [] in
    for i = 0 to n - 1 do
      list := i :: !list
    done;
    checksum := !checksum + List.length !list
  done;
  !checksum

let bench_sort shuffled iters =
  let checksum = ref 0 in
  for _iter = 0 to iters - 1 do
    let sorted = List.stable_sort compare shuffled in
    let len = List.length sorted in
    checksum :=
      !checksum + len + List.nth sorted 0 + List.nth sorted (len / 2) + List.nth sorted (len - 1)
  done;
  !checksum

let bench_filter list iters =
  let checksum = ref 0 in
  for _iter = 0 to iters - 1 do
    checksum := !checksum + List.length (List.filter (fun x -> x mod 2 = 0) list)
  done;
  !checksum

let bench_fold list iters =
  let checksum = ref 0 in
  for _iter = 0 to iters - 1 do
    checksum := !checksum + List.fold_left ( + ) 0 list
  done;
  !checksum

let bench_reverse list iters =
  let checksum = ref 0 in
  for _iter = 0 to iters - 1 do
    checksum := !checksum + List.length (List.rev list)
  done;
  !checksum

let bench_concat a b iters =
  let checksum = ref 0 in
  for _iter = 0 to iters - 1 do
    checksum := !checksum + List.length (a @ b)
  done;
  !checksum

let () =
  let n = 10_000 in
  Printf.printf "append checksum: %d\n" (bench_append n 500);
  let shuffled = make_shuffled n in
  Printf.printf "sort checksum: %d\n" (bench_sort shuffled 200);
  let seq = List.init n Fun.id in
  Printf.printf "filter checksum: %d\n" (bench_filter seq 500);
  Printf.printf "fold checksum: %d\n" (bench_fold seq 2000);
  Printf.printf "reverse checksum: %d\n" (bench_reverse seq 1000);
  let half = n / 2 in
  let a = List.init half Fun.id in
  let b = List.init (n - half) (fun i -> i + half) in
  Printf.printf "concat checksum: %d\n" (bench_concat a b 1000)
