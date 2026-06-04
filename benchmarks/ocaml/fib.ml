let rec fib n =
  match n with
  | 0 -> 0
  | 1 -> 1
  | _ -> fib (n - 1) + fib (n - 2)

let () =
  let result = fib 40 in
  Printf.printf "Fib(40) = %d\n" result
