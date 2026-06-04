let solar_mass =
  let pi = 4.0 *. atan 1.0 in
  4.0 *. pi *. pi

let days_per_year = 365.24
let n_bodies = 5

let int_arg default =
  if Array.length Sys.argv > 1 then
    try int_of_string Sys.argv.(1) with Failure _ -> default
  else default

let init_bodies () =
  let bx = Array.make n_bodies 0.0 in
  let by = Array.make n_bodies 0.0 in
  let bz = Array.make n_bodies 0.0 in
  let bvx = Array.make n_bodies 0.0 in
  let bvy = Array.make n_bodies 0.0 in
  let bvz = Array.make n_bodies 0.0 in
  let bmass = Array.make n_bodies 0.0 in
  bmass.(0) <- solar_mass;
  bx.(1) <- 4.841431442464721;
  by.(1) <- -1.1603200440274284;
  bz.(1) <- -0.10362204447112311;
  bvx.(1) <- 0.001660076642744037 *. days_per_year;
  bvy.(1) <- 0.007699011184197404 *. days_per_year;
  bvz.(1) <- -0.0000690460016972063 *. days_per_year;
  bmass.(1) <- 0.0009547919384243266 *. solar_mass;
  bx.(2) <- 8.34336671824458;
  by.(2) <- 4.124798564124305;
  bz.(2) <- -0.4035234171143214;
  bvx.(2) <- -0.002767425107268624 *. days_per_year;
  bvy.(2) <- 0.004998528012349172 *. days_per_year;
  bvz.(2) <- 0.00002304172975737639 *. days_per_year;
  bmass.(2) <- 0.0002858859806661308 *. solar_mass;
  bx.(3) <- 12.894369562139131;
  by.(3) <- -15.111151401698631;
  bz.(3) <- -0.22330757889265573;
  bvx.(3) <- 0.002964601375647616 *. days_per_year;
  bvy.(3) <- 0.0023784717395948095 *. days_per_year;
  bvz.(3) <- -0.00002965895685402376 *. days_per_year;
  bmass.(3) <- 0.00004366244043351563 *. solar_mass;
  bx.(4) <- 15.379697114850917;
  by.(4) <- -25.919314609987964;
  bz.(4) <- 0.17925877295037118;
  bvx.(4) <- 0.0026806777249038932 *. days_per_year;
  bvy.(4) <- 0.001628241700382423 *. days_per_year;
  bvz.(4) <- -0.00009515922545197159 *. days_per_year;
  bmass.(4) <- 0.00005151389020466115 *. solar_mass;
  (bx, by, bz, bvx, bvy, bvz, bmass)

let offset_momentum bvx bvy bvz bmass =
  let px = ref 0.0 in
  let py = ref 0.0 in
  let pz = ref 0.0 in
  for i = 0 to Array.length bmass - 1 do
    px := !px +. (bvx.(i) *. bmass.(i));
    py := !py +. (bvy.(i) *. bmass.(i));
    pz := !pz +. (bvz.(i) *. bmass.(i))
  done;
  bvx.(0) <- -.(!px) /. solar_mass;
  bvy.(0) <- -.(!py) /. solar_mass;
  bvz.(0) <- -.(!pz) /. solar_mass

let energy bx by bz bvx bvy bvz bmass =
  let e = ref 0.0 in
  for i = 0 to Array.length bx - 1 do
    e :=
      !e
      +. (0.5 *. bmass.(i)
         *. ((bvx.(i) *. bvx.(i)) +. (bvy.(i) *. bvy.(i)) +. (bvz.(i) *. bvz.(i))));
    for j = i + 1 to Array.length bx - 1 do
      let dx = bx.(i) -. bx.(j) in
      let dy = by.(i) -. by.(j) in
      let dz = bz.(i) -. bz.(j) in
      let dist = sqrt ((dx *. dx) +. (dy *. dy) +. (dz *. dz)) in
      e := !e -. (bmass.(i) *. bmass.(j) /. dist)
    done
  done;
  !e

let advance bx by bz bvx bvy bvz bmass dt =
  for i = 0 to Array.length bx - 1 do
    for j = i + 1 to Array.length bx - 1 do
      let dx = bx.(i) -. bx.(j) in
      let dy = by.(i) -. by.(j) in
      let dz = bz.(i) -. bz.(j) in
      let dist_sq = (dx *. dx) +. (dy *. dy) +. (dz *. dz) in
      let dist = sqrt dist_sq in
      let mag = dt /. (dist_sq *. dist) in
      bvx.(i) <- bvx.(i) -. (dx *. bmass.(j) *. mag);
      bvy.(i) <- bvy.(i) -. (dy *. bmass.(j) *. mag);
      bvz.(i) <- bvz.(i) -. (dz *. bmass.(j) *. mag);
      bvx.(j) <- bvx.(j) +. (dx *. bmass.(i) *. mag);
      bvy.(j) <- bvy.(j) +. (dy *. bmass.(i) *. mag);
      bvz.(j) <- bvz.(j) +. (dz *. bmass.(i) *. mag)
    done
  done;
  for i = 0 to Array.length bx - 1 do
    bx.(i) <- bx.(i) +. (dt *. bvx.(i));
    by.(i) <- by.(i) +. (dt *. bvy.(i));
    bz.(i) <- bz.(i) +. (dt *. bvz.(i))
  done

let () =
  let n = int_arg 1000 in
  let bx, by, bz, bvx, bvy, bvz, bmass = init_bodies () in
  offset_momentum bvx bvy bvz bmass;
  Printf.printf "%.9f\n" (energy bx by bz bvx bvy bvz bmass);
  for _i = 0 to n - 1 do
    advance bx by bz bvx bvy bvz bmass 0.01
  done;
  Printf.printf "%.9f\n" (energy bx by bz bvx bvy bvz bmass)
