let int_arg default =
  if Array.length Sys.argv > 1 then
    try int_of_string Sys.argv.(1) with Failure _ -> default
  else default

let fannkuch n =
  let perm = Array.make n 0 in
  let perm1 = Array.init n Fun.id in
  let count = Array.make n 0 in
  let max_flips = ref 0 in
  let checksum = ref 0 in
  let perm_count = ref 0 in
  let r = ref n in
  let finished = ref false in
  while not !finished do
    while !r > 1 do
      count.(!r - 1) <- !r;
      decr r
    done;
    Array.blit perm1 0 perm 0 n;
    let flips = ref 0 in
    let k = ref perm.(0) in
    while !k <> 0 do
      let i = ref 0 in
      let j = ref !k in
      while !i < !j do
        let tmp = perm.(!i) in
        perm.(!i) <- perm.(!j);
        perm.(!j) <- tmp;
        incr i;
        decr j
      done;
      incr flips;
      k := perm.(0)
    done;
    if !flips > !max_flips then max_flips := !flips;
    if !perm_count mod 2 = 0 then checksum := !checksum + !flips
    else checksum := !checksum - !flips;
    incr perm_count;
    let advanced = ref false in
    while not !advanced do
      if !r = n then (
        Printf.printf "%d\nPfannkuchen(%d) = %d\n" !checksum n !max_flips;
        finished := true;
        advanced := true)
      else (
        let perm0 = perm1.(0) in
        for i = 0 to !r - 1 do
          perm1.(i) <- perm1.(i + 1)
        done;
        perm1.(!r) <- perm0;
        count.(!r) <- count.(!r) - 1;
        if count.(!r) > 0 then advanced := true else incr r)
    done
  done

let () = fannkuch (int_arg 10)
