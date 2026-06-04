let line_width = 60

let sequences =
  [
    ( ">ONE Homo sapiens alu",
      "CTTGGCACCCGAGCAGCTCAAGGAGATGGCCACCACGCTGCCTGCCGCTGACCTCCTGGCGAAGCTGACCTCCTGGCGAAGATGCCACCACGCTGCCTGCC" );
    ( ">TWO IUB ambiguity codes",
      "ATGGCCAATGCCACTGCCGTCGTTTTACACAACGTTTGCCACCACGCTGCCTGCCGCTGACCTCCTGGCGAAGCTGAAGATGCCACCACGCTGCCTGCCGCTGA" );
    ( ">THREE Homo sapiens frequency",
      "GCCACTGCCACCGGCAATCGCAAATGTGCCACTGCATCGTTTTACACNNNNNGTTTGCCACCACGCTGCCTGCCGCTGACCTCCTGGCGAAGCTGACCTCCTGGCGAAGCTGAAGATGCCACCACGCTGCCTGCCGCTGAMRWSYKVHDBN" );
  ]

let int_arg default =
  if Array.length Sys.argv > 1 then
    try int_of_string Sys.argv.(1) with Failure _ -> default
  else default

let complement = function
  | 'A' -> 'T'
  | 'T' -> 'A'
  | 'C' -> 'G'
  | 'G' -> 'C'
  | 'M' -> 'K'
  | 'K' -> 'M'
  | 'R' -> 'Y'
  | 'Y' -> 'R'
  | 'W' -> 'W'
  | 'S' -> 'S'
  | 'V' -> 'B'
  | 'B' -> 'V'
  | 'H' -> 'D'
  | 'D' -> 'H'
  | 'N' -> 'N'
  | 'a' -> 't'
  | 't' -> 'a'
  | 'c' -> 'g'
  | 'g' -> 'c'
  | 'm' -> 'k'
  | 'k' -> 'm'
  | 'r' -> 'y'
  | 'y' -> 'r'
  | 'w' -> 'w'
  | 's' -> 's'
  | 'v' -> 'b'
  | 'b' -> 'v'
  | 'h' -> 'd'
  | 'd' -> 'h'
  | 'n' -> 'n'
  | c -> c

let repeat_string s n =
  let buf = Buffer.create (String.length s * max 0 n) in
  for _i = 1 to n do
    Buffer.add_string buf s
  done;
  Buffer.contents buf

let reverse_complement seq =
  let n = String.length seq in
  let result = Bytes.create n in
  for i = 0 to n - 1 do
    Bytes.set result i (complement seq.[n - 1 - i])
  done;
  Bytes.unsafe_to_string result

let print_wrapped seq =
  let pos = ref 0 in
  while !pos < String.length seq do
    let len = min line_width (String.length seq - !pos) in
    print_endline (String.sub seq !pos len);
    pos := !pos + len
  done

let () =
  let n = int_arg 1 in
  let total = ref 0 in
  List.iter
    (fun (header, seq) ->
      let full_seq = repeat_string seq n in
      let rc = reverse_complement full_seq in
      total := !total + String.length rc;
      print_endline header;
      print_wrapped rc)
    sequences;
  Printf.printf "Total nucleotides: %d\n" !total
