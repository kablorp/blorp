(* Compiler-shaped code emission benchmark.
   Models generated C emission from a simple IR using OCaml Buffer, which is
   the realistic baseline for compiler output construction. *)

let emit_statement buf function_id block_id statement_id =
  let target = (statement_id + function_id + block_id) mod 17 in
  let left = ((statement_id * 3) + function_id) mod 23 in
  let right = ((block_id * 5) + statement_id) mod 29 in
  Buffer.add_string buf "  v";
  Buffer.add_string buf (string_of_int target);
  Buffer.add_string buf " = v";
  Buffer.add_string buf (string_of_int left);
  Buffer.add_string buf " + ";
  Buffer.add_string buf (string_of_int right);
  Buffer.add_string buf ";\n"

let emit_block buf function_id block_id statements =
  Buffer.add_string buf "block_";
  Buffer.add_string buf (string_of_int block_id);
  Buffer.add_string buf ":\n";
  for statement_id = 0 to statements - 1 do
    emit_statement buf function_id block_id statement_id
  done;
  if block_id mod 3 = 0 then (
    Buffer.add_string buf "  goto block_";
    Buffer.add_string buf (string_of_int (block_id + 1));
    Buffer.add_string buf ";\n")
  else (
    Buffer.add_string buf "  acc += v";
    Buffer.add_string buf (string_of_int (block_id mod 17));
    Buffer.add_string buf ";\n")

let emit_function buf function_id blocks statements =
  Buffer.add_string buf "static long f";
  Buffer.add_string buf (string_of_int function_id);
  Buffer.add_string buf "(long seed) {\n";
  Buffer.add_string buf "  long acc = seed;\n";
  for i = 0 to 23 do
    Buffer.add_string buf "  long v";
    Buffer.add_string buf (string_of_int i);
    Buffer.add_string buf " = seed + ";
    Buffer.add_string buf (string_of_int (function_id + i));
    Buffer.add_string buf ";\n"
  done;
  for block_id = 0 to blocks - 1 do
    emit_block buf function_id block_id statements
  done;
  Buffer.add_string buf "  return acc;\n}\n"

let emit_program functions blocks statements =
  let buf = Buffer.create (functions * blocks * statements * 24) in
  Buffer.add_string buf "/* generated benchmark program */\n";
  for function_id = 0 to functions - 1 do
    emit_function buf function_id blocks statements
  done;
  Buffer.contents buf

let checksum_text text =
  let checksum = ref 0 in
  for i = 0 to String.length text - 1 do
    checksum := (!checksum * 33) + Char.code text.[i]
  done;
  !checksum

let () =
  let text = emit_program 120 10 8 in
  Printf.printf "compiler_emit checksum: %d\n" (checksum_text text);
  Printf.printf "compiler_emit bytes: %d\n" (String.length text)
