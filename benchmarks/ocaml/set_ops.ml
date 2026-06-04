let bench_build n iters =
  let s = ref (Hashtbl.create n) in
  for _iter = 0 to iters - 1 do
    let next = Hashtbl.create n in
    for i = 0 to n - 1 do
      Hashtbl.replace next i ()
    done;
    s := next
  done;
  !s

let bench_contains_hit s n iters =
  let hits = ref 0 in
  for _iter = 0 to iters - 1 do
    for i = 0 to n - 1 do
      if Hashtbl.mem s i then incr hits
    done
  done;
  !hits

let bench_contains_miss s n iters =
  let misses = ref 0 in
  for _iter = 0 to iters - 1 do
    for i = n to n + n - 1 do
      if not (Hashtbl.mem s i) then incr misses
    done
  done;
  !misses

let bench_union a b iters =
  let checksum = ref 0 in
  for _iter = 0 to iters - 1 do
    let result = Hashtbl.create (Hashtbl.length a + Hashtbl.length b) in
    Hashtbl.iter (fun key () -> Hashtbl.replace result key ()) a;
    Hashtbl.iter (fun key () -> Hashtbl.replace result key ()) b;
    checksum := !checksum + Hashtbl.length result
  done;
  !checksum

let bench_intersect a b iters =
  let checksum = ref 0 in
  for _iter = 0 to iters - 1 do
    let result = Hashtbl.create (Hashtbl.length a) in
    Hashtbl.iter (fun key () -> if Hashtbl.mem b key then Hashtbl.replace result key ()) a;
    checksum := !checksum + Hashtbl.length result
  done;
  !checksum

let bench_difference a b iters =
  let checksum = ref 0 in
  for _iter = 0 to iters - 1 do
    let result = Hashtbl.create (Hashtbl.length a) in
    Hashtbl.iter (fun key () -> if not (Hashtbl.mem b key) then Hashtbl.replace result key ()) a;
    checksum := !checksum + Hashtbl.length result
  done;
  !checksum

let range_set start stop =
  let s = Hashtbl.create (max 0 (stop - start)) in
  for i = start to stop - 1 do
    Hashtbl.replace s i ()
  done;
  s

let () =
  let n = 10_000 in
  let s = bench_build n 200 in
  print_endline "build: done";
  Printf.printf "contains_hit: %d\n" (bench_contains_hit s n 200);
  Printf.printf "contains_miss: %d\n" (bench_contains_miss s n 200);
  let a = range_set 0 5000 in
  let b = range_set 5000 10000 in
  Printf.printf "union: %d\n" (bench_union a b 500);
  let c = range_set 0 n in
  let d = range_set (n / 2) ((n / 2) + n) in
  Printf.printf "intersect: %d\n" (bench_intersect c d 500);
  Printf.printf "difference: %d\n" (bench_difference c d 500)
