(* Pure numeric loop benchmark: Collatz sequence. *)

let collatz_steps start =
  let n = ref start in
  let steps = ref 0 in
  while !n <> 1 do
    if !n mod 2 = 0 then n := !n / 2 else n := (!n * 3) + 1;
    incr steps
  done;
  !steps

let () =
  let total_steps = ref 0 in
  for i = 1 to 999_999 do
    total_steps := !total_steps + collatz_steps i
  done;
  Printf.printf "Total Collatz steps: %d\n" !total_steps
