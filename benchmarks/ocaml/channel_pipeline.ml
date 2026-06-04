type 'a bounded_queue = {
  items : 'a Queue.t;
  capacity : int;
  mutex : Mutex.t;
  nonempty : Condition.t;
  nonfull : Condition.t;
  mutable closed : bool;
}

let make_bounded_queue capacity =
  {
    items = Queue.create ();
    capacity;
    mutex = Mutex.create ();
    nonempty = Condition.create ();
    nonfull = Condition.create ();
    closed = false;
  }

let queue_send q value =
  Mutex.lock q.mutex;
  while Queue.length q.items >= q.capacity do
    Condition.wait q.nonfull q.mutex
  done;
  Queue.add value q.items;
  Condition.signal q.nonempty;
  Mutex.unlock q.mutex

let queue_close q =
  Mutex.lock q.mutex;
  q.closed <- true;
  Condition.broadcast q.nonempty;
  Mutex.unlock q.mutex

let queue_recv q =
  Mutex.lock q.mutex;
  while Queue.is_empty q.items && not q.closed do
    Condition.wait q.nonempty q.mutex
  done;
  let result =
    if Queue.is_empty q.items then None
    else
      let value = Queue.take q.items in
      Condition.signal q.nonfull;
      Some value
  in
  Mutex.unlock q.mutex;
  result

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

let producer items output =
  for i = 0 to items - 1 do
    queue_send output i
  done;
  queue_close output

let pipeline_worker input output rounds =
  let processed = ref 0 in
  let running = ref true in
  while !running do
    match queue_recv input with
    | Some value ->
        queue_send output (heavy_work value rounds);
        incr processed
    | None -> running := false
  done;
  !processed

let receive_outputs output items =
  let checksum = ref 0 in
  for _received = 1 to items do
    match queue_recv output with
    | Some value -> checksum := !checksum + value
    | None -> ()
  done;
  !checksum

let () =
  let workers = env_int "BENCH_THREADS" 4 in
  let items = env_int "BENCH_ITEMS" 20_000 in
  let rounds = env_int "BENCH_ROUNDS" 64 in
  let capacity = workers * 4 in
  let input = make_bounded_queue capacity in
  let output = make_bounded_queue capacity in
  let producer_thread = Thread.create (fun () -> producer items input) () in
  let processed = Array.make workers 0 in
  let worker_threads =
    Array.init workers (fun worker_id ->
        Thread.create
          (fun () -> processed.(worker_id) <- pipeline_worker input output rounds)
          ())
  in
  let checksum = receive_outputs output items in
  Thread.join producer_thread;
  Array.iter Thread.join worker_threads;
  let processed_total = Array.fold_left ( + ) 0 processed in
  queue_close output;
  Printf.printf "checksum: %d\n" checksum;
  Printf.printf "processed: %d\n" processed_total
