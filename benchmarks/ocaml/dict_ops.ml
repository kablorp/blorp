let bench_build n iters =
  let d = ref (Hashtbl.create n) in
  for _iter = 0 to iters - 1 do
    let next = Hashtbl.create n in
    for i = 0 to n - 1 do
      Hashtbl.replace next i (i * 7)
    done;
    d := next
  done;
  !d

let bench_lookup_hit d n iters =
  let checksum = ref 0 in
  for _iter = 0 to iters - 1 do
    for i = 0 to n - 1 do
      match Hashtbl.find_opt d i with
      | Some value -> checksum := !checksum + value
      | None -> ()
    done
  done;
  !checksum

let bench_lookup_miss d n iters =
  let misses = ref 0 in
  for _iter = 0 to iters - 1 do
    for i = n to n + n - 1 do
      if not (Hashtbl.mem d i) then incr misses
    done
  done;
  !misses

let bench_remove n iters =
  let removed = ref 0 in
  for _iter = 0 to iters - 1 do
    let d = Hashtbl.create n in
    for i = 0 to n - 1 do
      Hashtbl.replace d i (i * 7)
    done;
    for i = 0 to n - 1 do
      Hashtbl.remove d i;
      incr removed
    done
  done;
  !removed

let bench_iterate d iters =
  let total = ref 0 in
  for _iter = 0 to iters - 1 do
    Hashtbl.iter (fun _key value -> total := !total + value) d
  done;
  !total

let () =
  let n = 10_000 in
  let d = bench_build n 100 in
  print_endline "build: done";
  Printf.printf "lookup_hit checksum: %d\n" (bench_lookup_hit d n 100);
  Printf.printf "lookup_miss count: %d\n" (bench_lookup_miss d n 100);
  Printf.printf "remove count: %d\n" (bench_remove n 100);
  Printf.printf "iterate sum: %d\n" (bench_iterate d 1000)
