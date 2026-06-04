let () =
  let size = 1000 in
  let iterations = 10_000 in
  let arr1 = Array.init size Fun.id in
  let arr2 = Array.init size (fun i -> i * 2) in
  let final_sum = ref 0 in
  for _iter = 0 to iterations - 1 do
    let combined = Array.make size 0 in
    for i = 0 to size - 1 do
      combined.(i) <- arr1.(i) + arr2.(i)
    done;
    let scaled = Array.make size 0 in
    for i = 0 to size - 1 do
      scaled.(i) <- combined.(i) * 3
    done;
    let sum = ref 0 in
    for i = 0 to size - 1 do
      sum := !sum + scaled.(i)
    done;
    final_sum := !final_sum + !sum
  done;
  Printf.printf "Completed %d iterations, final sum: %d\n" iterations !final_sum
