let iters = 100_000

let test_string =
  "The quick brown fox jumps over the lazy dog. This is a test string for benchmarking purposes."

let chain_string =
  "   The quick brown fox jumps over the lazy dog. This is a test string for benchmarking purposes.   "

let starts_with_at s prefix index =
  let s_len = String.length s in
  let p_len = String.length prefix in
  if index + p_len > s_len then false
  else
    let ok = ref true in
    let i = ref 0 in
    while !ok && !i < p_len do
      if s.[index + !i] <> prefix.[!i] then ok := false;
      incr i
    done;
    !ok

let count_occurrences s needle =
  let needle_len = String.length needle in
  if needle_len = 0 then 0
  else
    let total = ref 0 in
    let i = ref 0 in
    while !i <= String.length s - needle_len do
      if starts_with_at s needle !i then (
        incr total;
        i := !i + needle_len)
      else incr i
    done;
    !total

let contains s needle =
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else
    let found = ref false in
    let i = ref 0 in
    while (not !found) && !i <= String.length s - needle_len do
      if starts_with_at s needle !i then found := true;
      incr i
    done;
    !found

let replace_all s old_value new_value =
  let old_len = String.length old_value in
  if old_len = 0 then s
  else
    let out = Buffer.create (String.length s) in
    let i = ref 0 in
    while !i < String.length s do
      if starts_with_at s old_value !i then (
        Buffer.add_string out new_value;
        i := !i + old_len)
      else (
        Buffer.add_char out s.[!i];
        incr i)
    done;
    Buffer.contents out

let reverse_string s =
  let n = String.length s in
  let bytes = Bytes.create n in
  for i = 0 to n - 1 do
    Bytes.set bytes i s.[n - 1 - i]
  done;
  Bytes.unsafe_to_string bytes

let bench_count s needle iters =
  let total = ref 0 in
  for _i = 0 to iters - 1 do
    total := !total + count_occurrences s needle
  done;
  !total

let bench_contains s needle iters =
  let total = ref 0 in
  for _i = 0 to iters - 1 do
    if contains s needle then incr total
  done;
  !total

let bench_replace s old_value new_value iters =
  let total = ref 0 in
  for _i = 0 to iters - 1 do
    total := !total + String.length (replace_all s old_value new_value)
  done;
  !total

let bench_substring s iters =
  let total = ref 0 in
  for i = 0 to iters - 1 do
    let start = i mod 16 in
    total := !total + String.length (String.sub s start 24)
  done;
  !total

let bench_split s delim iters =
  let total = ref 0 in
  let ch = delim.[0] in
  for _i = 0 to iters - 1 do
    total := !total + List.length (String.split_on_char ch s)
  done;
  !total

let bench_upper s iters =
  let total = ref 0 in
  for _i = 0 to iters - 1 do
    total := !total + String.length (String.uppercase_ascii s)
  done;
  !total

let bench_lower s iters =
  let total = ref 0 in
  for _i = 0 to iters - 1 do
    total := !total + String.length (String.lowercase_ascii s)
  done;
  !total

let bench_reverse s iters =
  let total = ref 0 in
  for _i = 0 to iters - 1 do
    total := !total + String.length (reverse_string s)
  done;
  !total

let bench_trim iters =
  let padded = "   hello world   " in
  let total = ref 0 in
  for _i = 0 to iters - 1 do
    total := !total + String.length (String.trim padded)
  done;
  !total

let bench_chain_window_replace s iters =
  let total = ref 0 in
  for i = 0 to iters - 1 do
    let start = i mod 16 in
    let trimmed = String.trim s in
    let window = String.sub trimmed start 40 in
    total := !total + String.length (replace_all window " " "_")
  done;
  !total

let bench_chain_case_replace s iters =
  let total = ref 0 in
  for _i = 0 to iters - 1 do
    total :=
      !total
      + String.length
          (String.uppercase_ascii (replace_all (String.lowercase_ascii s) "the" "a"))
  done;
  !total

let bench_chain_trim_reverse iters =
  let padded = "   hello world   " in
  let total = ref 0 in
  for _i = 0 to iters - 1 do
    let trimmed = String.trim padded in
    let reversed = reverse_string trimmed in
    total := !total + String.length (replace_all reversed "l" "L")
  done;
  !total

let () =
  Printf.printf "count checksum: %d\n" (bench_count test_string "e" iters);
  Printf.printf "contains checksum: %d\n" (bench_contains test_string "fox" iters);
  Printf.printf "replace_same checksum: %d\n" (bench_replace test_string "the" "THE" iters);
  Printf.printf "replace_grow checksum: %d\n" (bench_replace test_string "dog" "catapult" iters);
  Printf.printf "replace_shrink checksum: %d\n"
    (bench_replace test_string "benchmarking" "bench" iters);
  Printf.printf "substring checksum: %d\n" (bench_substring test_string iters);
  Printf.printf "split checksum: %d\n" (bench_split test_string " " iters);
  Printf.printf "upper checksum: %d\n" (bench_upper test_string iters);
  Printf.printf "lower checksum: %d\n" (bench_lower test_string iters);
  Printf.printf "reverse checksum: %d\n" (bench_reverse test_string iters);
  Printf.printf "trim checksum: %d\n" (bench_trim iters);
  Printf.printf "chain_window_replace checksum: %d\n"
    (bench_chain_window_replace chain_string iters);
  Printf.printf "chain_case_replace checksum: %d\n" (bench_chain_case_replace test_string iters);
  Printf.printf "chain_trim_reverse checksum: %d\n" (bench_chain_trim_reverse iters)
