let () =
  let size = 1000 in
  let iterations = 10_000 in
  let arr = Array.init size Fun.id in
  let total = ref 0 in
  for _iter = 0 to iterations - 1 do
    let sum = ref 0 in
    for i = 0 to size - 1 do
      sum := !sum + arr.(i)
    done;
    total := !total + !sum
  done;
  Printf.printf "Completed %d iterations, total: %d\n" iterations !total
