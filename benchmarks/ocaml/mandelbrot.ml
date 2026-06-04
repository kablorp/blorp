let int_arg default =
  if Array.length Sys.argv > 1 then
    try int_of_string Sys.argv.(1) with Failure _ -> default
  else default

let in_mandelbrot cr ci max_iter =
  let zr = ref 0.0 in
  let zi = ref 0.0 in
  let escaped = ref false in
  let i = ref 0 in
  while !i < max_iter && not !escaped do
    let tr = (!zr *. !zr) -. (!zi *. !zi) +. cr in
    let ti = (2.0 *. !zr *. !zi) +. ci in
    zr := tr;
    zi := ti;
    if (!zr *. !zr) +. (!zi *. !zi) > 4.0 then escaped := true;
    incr i
  done;
  not !escaped

let () =
  let n = int_arg 200 in
  let max_iter = 50 in
  for y = 0 to n - 1 do
    let row = Bytes.create n in
    let ci = (2.0 *. float_of_int y /. float_of_int n) -. 1.0 in
    for x = 0 to n - 1 do
      let cr = (2.0 *. float_of_int x /. float_of_int n) -. 1.5 in
      Bytes.set row x (if in_mandelbrot cr ci max_iter then '#' else '.')
    done;
    print_endline (Bytes.unsafe_to_string row)
  done
