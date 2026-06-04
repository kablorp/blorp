let sample_dna =
  "GGTATTTTAATTTATAGTGGTATTTTAATTTATAGT"
  ^ "ACGTACGTACGTACGTGGTATTTTAATTTATAGTAA"
  ^ "CGTGGTATTTTAATTTATAGTTGCAGGTATTTTAAT"
  ^ "TTATAGTACGGTATTACGTGGTATTTTAATTTATAG"
  ^ "TGGTATTTTAATTTATAGTTCGATCGATCGATCGAT"
  ^ "GGTAACGTACGTGGTATTTTAATTTATAGTTTTAAC"
  ^ "GGTATTTTAATTTATAGTAGCTAGCTAGCTAGCTAG"
  ^ "ACGTACGTGGTATTTTAATTTATAGTTGCATGCATG"

type knuc = { name : string; count : int; order : int }

let int_arg default =
  if Array.length Sys.argv > 1 then
    try int_of_string Sys.argv.(1) with Failure _ -> default
  else default

let generate_sequence n =
  if n <= 0 then ""
  else
    let buf = Buffer.create n in
    while Buffer.length buf < n do
      let remaining = n - Buffer.length buf in
      if remaining < String.length sample_dna then Buffer.add_substring buf sample_dna 0 remaining
      else Buffer.add_string buf sample_dna
    done;
    Buffer.contents buf

let count_frequencies seq length =
  let counts = Hashtbl.create 1024 in
  let order = ref [] in
  let next_order = ref 0 in
  for i = 0 to String.length seq - length do
    let key = String.sub seq i length in
    if not (Hashtbl.mem counts key) then (
      order := (key, !next_order) :: !order;
      incr next_order);
    Hashtbl.replace counts key (1 + Option.value (Hashtbl.find_opt counts key) ~default:0)
  done;
  (counts, List.rev !order)

let write_frequencies seq length =
  let counts, order = count_frequencies seq length in
  let total = ref 0 in
  let nucs =
    List.map
      (fun (name, order) ->
        let count = Option.value (Hashtbl.find_opt counts name) ~default:0 in
        total := !total + count;
        { name; count; order })
      order
  in
  let sorted =
    List.stable_sort
      (fun a b ->
        let by_count = compare b.count a.count in
        if by_count <> 0 then by_count else compare a.order b.order)
      nucs
  in
  List.iter
    (fun nuc -> Printf.printf "%s %.3f\n" nuc.name (100.0 *. float_of_int nuc.count /. float_of_int !total))
    sorted;
  print_endline ""

let write_count seq fragment =
  let counts, _order = count_frequencies seq (String.length fragment) in
  Printf.printf "%d\t%s\n" (Option.value (Hashtbl.find_opt counts fragment) ~default:0) fragment

let () =
  let n = int_arg 100 in
  let seq = generate_sequence n in
  write_frequencies seq 1;
  write_frequencies seq 2;
  List.iter
    (write_count seq)
    [ "GGT"; "GGTA"; "GGTATT"; "GGTATTTTAATT"; "GGTATTTTAATTTATAGT" ]
