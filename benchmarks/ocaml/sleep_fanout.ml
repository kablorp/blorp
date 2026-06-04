let env_int name fallback =
  match Sys.getenv_opt name with
  | None -> fallback
  | Some raw -> (
      try
        let value = int_of_string raw in
        if value > 0 then value else fallback
      with Failure _ -> fallback)

let () =
  let tasks = env_int "BENCH_SLEEP_TASKS" 512 in
  let sleep_ms = env_int "BENCH_SLEEP_MS" 5 in
  let results = Array.make tasks 0 in
  let threads =
    Array.init tasks (fun id ->
        Thread.create
          (fun () ->
            Thread.delay (float_of_int sleep_ms /. 1000.0);
            results.(id) <- id)
          ())
  in
  Array.iter Thread.join threads;
  let checksum = Array.fold_left ( + ) 0 results in
  Printf.printf "checksum: %d\n" checksum
