let env_int name fallback =
  match Sys.getenv_opt name with
  | None -> fallback
  | Some raw -> (
      try
        let value = int_of_string raw in
        if value > 0 then value else fallback
      with Failure _ -> fallback)

let heavy_work seed rounds =
  let acc = ref (seed + 1) in
  for i = 0 to rounds - 1 do
    acc := ((!acc * 1_103_515_245) + 12_345 + i + seed) mod 2_147_483_647
  done;
  !acc mod 1_000_003

let worker_sum worker_id workers items rounds =
  let checksum = ref 0 in
  let i = ref worker_id in
  while !i < items do
    checksum := !checksum + heavy_work !i rounds;
    i := !i + workers
  done;
  !checksum

let () =
  let workers = env_int "BENCH_THREADS" 4 in
  let items = env_int "BENCH_ITEMS" 10_000 in
  let rounds = env_int "BENCH_ROUNDS" 1000 in
  let partials = Array.make workers 0 in
  let threads =
    Array.init workers (fun worker_id ->
        Thread.create
          (fun () ->
            partials.(worker_id) <- worker_sum worker_id workers items rounds)
          ())
  in
  Array.iter Thread.join threads;
  let checksum = Array.fold_left ( + ) 0 partials in
  Printf.printf "checksum: %d\n" checksum
