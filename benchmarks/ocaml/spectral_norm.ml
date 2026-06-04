let int_arg default =
  if Array.length Sys.argv > 1 then
    try int_of_string Sys.argv.(1) with Failure _ -> default
  else default

let a i j =
  1.0 /. float_of_int (((i + j) * (i + j + 1) / 2) + i + 1)

let multiply_av n v =
  Array.init n (fun i ->
      let sum = ref 0.0 in
      for j = 0 to n - 1 do
        sum := !sum +. (a i j *. v.(j))
      done;
      !sum)

let multiply_atv n v =
  Array.init n (fun i ->
      let sum = ref 0.0 in
      for j = 0 to n - 1 do
        sum := !sum +. (a j i *. v.(j))
      done;
      !sum)

let multiply_atav n v =
  let u = multiply_av n v in
  multiply_atv n u

let () =
  let n = int_arg 500 in
  let u = ref (Array.make n 1.0) in
  let v = ref (Array.make n 0.0) in
  for _i = 0 to 9 do
    v := multiply_atav n !u;
    u := multiply_atav n !v
  done;
  let vbv = ref 0.0 in
  let vv = ref 0.0 in
  for i = 0 to n - 1 do
    vbv := !vbv +. ((!u).(i) *. (!v).(i));
    vv := !vv +. ((!v).(i) *. (!v).(i))
  done;
  Printf.printf "%.9f\n" (sqrt (!vbv /. !vv))
